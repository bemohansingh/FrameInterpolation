//
//  MyVideoProcessor.swift
//  Frame
//
//  Created by Mohan Singh Thagunna on 30/12/2023.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage
import Metal
// Import other necessary frameworks like a machine learning framework for motion estimation

class MYVideoProcessor {
    // Enum for custom error codes
    enum VideoProcessorError: Int {
        case metalNotSupported = 1
        case commandQueueCreationFailed = 2
        case kernelFunctionLoadingFailed = 3
        case commandBufferOrEncoderCreationFailed = 4
        case textureCreationFailed = 5
        case outputTextureCreationFailed = 6
        case cgImageConversionFailed = 7
        case pixelBufferCreationFailed = 8
        case assetReaderCreationFailed = 9
        case assetNotExportable = 10
        case exportSessionEndedWithUnknownStatus = 11
    }
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var computePipelineState: MTLComputePipelineState!
    private let videoProcessingQueue = DispatchQueue(label: "com.example.VideoProcessingQueue")
    
    init() throws {
        // Initialize Metal device and command queue
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "VideoProcessor", code: VideoProcessorError.metalNotSupported.rawValue, userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this device"])
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Set up the compute pipeline with a Metal shader for frame interpolation
        guard let defaultLibrary = device.makeDefaultLibrary(),
              let kernelFunction = defaultLibrary.makeFunction(name: "frameInterpolationKernel") else {
            throw NSError(domain: "VideoProcessor", code: VideoProcessorError.kernelFunctionLoadingFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Failed to load the kernel function from the default library"])
        }
        self.computePipelineState = try device.makeComputePipelineState(function: kernelFunction)
    }
    
    // Function to process the video
    func processVideo(atPath inputPath: URL, completion: @escaping (Result<AVAsset, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load video
                let video = try self.loadVideo(fromPath: inputPath)
                
                print("Loaded Video")
                
                // Extract frames
                let frames = try self.extractFrames(fromVideo: video)
                
                print("Extracted Frames \(frames.count)")
                
                // Interpolate frames
                let interpolatedFrames = try self.interpolateFrames(frames)
                print("Extracted Frames \(frames.count)")
                print("Interpolated Frames Completed \(interpolatedFrames.count)")
                
                let totalFrams = self.interleaveArrays(array1:frames, array2:interpolatedFrames)
                print("Total Frames \(totalFrams.count)")
                // Adjust frame rate
                let adjustedVideo = try self.adjustFrameRate(forVideo: video, withFrames: totalFrams, targetFrameRate: 60)
                print("Adjusted Frames Completed")
                print("================================")
                print("=========OLD Frame Rate=========")
                self.isVideo60fps(asset: video)
                print("=========NEW Frame Rate=========")
                self.isVideo60fps(asset: adjustedVideo)
                print("================================")
                completion(.success(adjustedVideo))
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }}
    func interleaveArrays<T>(array1: [T], array2: [T]) -> [T] {
        var result: [T] = []

        // Determine the minimum count to avoid index out of range
        let count = min(array1.count, array2.count)

        for i in 0..<count {
            result.append(array1[i])
            result.append(array2[i])
        }

        // Add remaining elements from the longer array, if any
        if array1.count > count {
            result.append(contentsOf: array1[count...])
        } else if array2.count > count {
            result.append(contentsOf: array2[count...])
        }

        return result
    }
    private func adjustFrameRate(forVideo video: AVAsset, withFrames frames: [CGImage], targetFrameRate: Int) throws -> AVAsset {
        // Create an AVMutableComposition to hold the new video frames
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create composition track"])
        }
        
        // Calculate frame duration based on the desired frame rate
        let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        
        let videoTrack = video.tracks(withMediaType: .video)[0]
        // Insert each frame into the composition
        var currentTime = CMTime.zero
        for frame in frames {
            guard let buffer = try? createSampleBuffer(from: frame) else { continue }
            try compositionTrack.insertTimeRange(CMTimeRange(start: currentTime, duration: targetFrameDuration), of: videoTrack, at: currentTime)
            currentTime = CMTimeAdd(currentTime, targetFrameDuration)
        }
        
        
        let transformer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        transformer.setTransform(videoTrack.preferredTransform, at: CMTime.zero)
        
        let videoCompositionInstruction = AVMutableVideoCompositionInstruction()
        videoCompositionInstruction.timeRange = CMTimeRange(start: CMTime.zero, duration: composition.duration)
        videoCompositionInstruction.layerInstructions = [transformer]
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [videoCompositionInstruction]
        videoComposition.frameDuration = targetFrameDuration
        videoComposition.renderSize = CGSize(width: videoTrack.naturalSize.width, height: videoTrack.naturalSize.height)
        
        return composition
    }
    
    private func createSampleBuffer(from cgImage: CGImage) throws -> CMSampleBuffer {
        // Create a CVPixelBuffer from the CGImage
        let pixelBuffer = try self.createPixelBuffer(from: cgImage)
        
        // Create a CMVideoFormatDescription from the CVPixelBuffer
        var videoInfo: CMVideoFormatDescription?
        let formatDescriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &videoInfo)
        
        // Check if CMVideoFormatDescription creation was successful
        guard formatDescriptionStatus == noErr, let formatDescription = videoInfo else {
            throw NSError(domain: "VideoProcessor", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to create CMVideoFormatDescription"])
        }
        
        // Create a CMSampleBuffer from the CVPixelBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: CMTime.invalid, presentationTimeStamp: CMTime.invalid, decodeTimeStamp: CMTime.invalid)
        
        let sampleBufferStatus = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription, sampleTiming: &timingInfo, sampleBufferOut: &sampleBuffer)
        
        // Check if CMSampleBuffer creation was successful
        guard sampleBufferStatus == noErr, let buffer = sampleBuffer else {
            throw NSError(domain: "VideoProcessor", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unable to create CMSampleBuffer"])
        }
        
        return buffer
    }
    
    
    
    private func loadVideo(fromPath path: URL) throws -> AVAsset {
        //        let url = URL(fileURLWithPath: path)
        return AVAsset(url: path)
    }
    
    
    private func extractFrames(fromVideo video: AVAsset) throws -> [CGImage] {
        var frames: [CGImage] = []
        // Create an asset reader
        guard let assetReader = try? AVAssetReader(asset: video) else {
            throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAssetReader"])
        }
        // Get the video track
        guard let videoTrack = video.tracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video track available"])
        }
        // Configure reader output with the video track and settings
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
        ]
        let assetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        
        // Assign the output to the reader
        assetReader.add(assetReaderOutput)
        // Start reading
        assetReader.startReading()
        // Read the samples from the video track
        while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer(), CMSampleBufferIsValid(sampleBuffer) {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            
            // Create a CIImage from the CVPixelBuffer
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            
            // Convert CIImage to CGImage
            let context = CIContext(options: nil)
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                frames.append(cgImage)
            }
        }
        print("Frames Extracted \(frames.count)")
        return frames
    }
    
    
    private func interpolateFrames(_ frames: [CGImage]) throws -> [CGImage] {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this device"])
            }
            
            guard let commandQueue = device.makeCommandQueue() else {
                throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
            }
            let computePipelineState = try makeComputePipelineState(device: device)
            var interpolatedFrames: [CGImage] = []
            for i in 0..<frames.count - 1 {
                print("START 1")
                let currentTexture = try makeTexture(from: frames[i], device: device)
                let nextTexture = try makeTexture(from: frames[i + 1], device: device)
                let outputTexture = try makeEmptyTexture(matching: currentTexture, device: device)
                print("TOP 2")
                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                      let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw NSError(domain: "VideoProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer or encoder"])
                }
                commandEncoder.setComputePipelineState(computePipelineState)
                commandEncoder.setTexture(currentTexture, index: 0)
                commandEncoder.setTexture(nextTexture, index: 1)
                commandEncoder.setTexture(outputTexture, index: 2)
                print("MID 3")
                // The threadgroup size and count depends on your shader and texture size
                let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let threadgroupCount = MTLSize(width: (currentTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                                               height: (currentTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                                               depth: 1)
                
                commandEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
                commandEncoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                print("BOTTOM 4")
                if let cgImage = try convertTextureToCGImage(outputTexture) {
                    print("Adding Frame, Current count \(interpolatedFrames.count)")
                    interpolatedFrames.append(cgImage)
                }
            }
            print("Adding Frames Completed \(interpolatedFrames.count)")
            return interpolatedFrames
        } catch {
            print("Failed to interpolate Frame")
            throw error
        }}
    
    
    
    private func makeComputePipelineState(device: MTLDevice) throws -> MTLComputePipelineState {
        guard let defaultLibrary = device.makeDefaultLibrary(),
              let kernelFunction = defaultLibrary.makeFunction(name: "interpolationKernel") else {
            throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load the kernel function from the default library"])
        }
        
        return try device.makeComputePipelineState(function: kernelFunction)
    }
    
    
    func isVideo60fps(asset: AVAsset) -> Bool {
            // Assuming there is only one video track in the asset
            if let videoTrack = asset.tracks(withMediaType: .video).first {
                let frameRate = videoTrack.nominalFrameRate
                print("frameRate: \(frameRate)")
                return frameRate == 60.0
            } else {
                // No video track found
                return false
            }
    }
    
    private func makeTexture(from cgImage: CGImage, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: cgImage.width,
                                                                  height: cgImage.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite] // Include shaderWrite usage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: cgImage.width,
                                height: cgImage.height,
                                bitsPerComponent: 8,
                                bytesPerRow: 4 * cgImage.width,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        
        let region = MTLRegionMake2D(0, 0, cgImage.width, cgImage.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: context.data!, bytesPerRow: 4 * cgImage.width)
        
        return texture
    }
    
    
    private func makeEmptyTexture(matching texture: MTLTexture, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                                  width: texture.width,
                                                                  height: texture.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite] // Include shaderWrite usage
        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "VideoProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
        }
        return newTexture
    }
    
    
    private func convertTextureToCGImage(_ texture: MTLTexture) throws -> CGImage? {
        let width = texture.width
        let height = texture.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rawData = UnsafeMutableRawPointer.allocate(byteCount: width *  height * 4, alignment: 1)
        defer { rawData.deallocate() }
        
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(rawData, bytesPerRow: 4 * width, from: region, mipmapLevel: 0)
        
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        if let context = CGContext(data: rawData,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 4 * width,
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo),
           let cgImage = context.makeImage() {
            print("Successfully converted to CG Image")
            return cgImage
        } else {
            print("Failed to convert to CG Image")
            return nil
        }
    }
    
    private func createPixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let unwrappedBuffer = pixelBuffer else {
            throw NSError(domain: "VideoProcessor", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to create CVPixelBuffer"])
        }
        
        CVPixelBufferLockBaseAddress(unwrappedBuffer, [])
        let pixelData = CVPixelBufferGetBaseAddress(unwrappedBuffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(unwrappedBuffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(unwrappedBuffer, [])
        
        return unwrappedBuffer
    }
    
    
    func outputVideo(_ video: AVAsset, completion: @escaping (Result<String, Error>) -> Void) {
        // Check if the asset is exportable
        guard video.isExportable else {
            completion(.failure(NSError(domain: "VideoProcessor", code: 10, userInfo: [NSLocalizedDescriptionKey: "Asset is not exportable"])))
            return
        }
        
        let presets = [AVAssetExportPresetHighestQuality, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
        let fileTypes = [AVFileType.mov, AVFileType.mp4, AVFileType.m4v]
        
        func tryExport(presetsIndex: Int, fileTypeIndex: Int) {
            guard presetsIndex < presets.count, fileTypeIndex < fileTypes.count else {
                completion(.failure(NSError(domain: "VideoProcessor", code: 9, userInfo: [NSLocalizedDescriptionKey: "All export attempts failed."])))
                return
            }
            
            let preset = presets[presetsIndex]
            let fileType = fileTypes[fileTypeIndex]
            
            if let exportSession = AVAssetExportSession(asset: video, presetName: preset) {
                if exportSession.supportedFileTypes.contains(fileType) {
                    let outputURL = self.createUniqueVideoPath(withExtension: self.fileExtension(for: fileType))
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = fileType
                    
                    exportSession.exportAsynchronously {
                        DispatchQueue.main.async {
                            if let error = exportSession.error {
                                print("Export failed: \(error.localizedDescription)")
                                completion(.failure(NSError(domain: "VideoProcessor", code: 8, userInfo: [NSLocalizedDescriptionKey: "Export session ended with unknown status"])))
                                // Additional error details: error.userInfo
                            } else {
                                switch exportSession.status {
                                case .completed:
                                    completion(.success(outputURL.path))
                                case .failed, .cancelled:
                                    print("Export failed with preset \(preset) and fileType \(fileType.rawValue)")
                                    // Handle failure, try the next fileType or preset
                                    let nextFileTypeIndex = fileTypeIndex + 1
                                    if nextFileTypeIndex < fileTypes.count {
                                        tryExport(presetsIndex: presetsIndex, fileTypeIndex: nextFileTypeIndex)
                                    } else {
                                        tryExport(presetsIndex: presetsIndex + 1, fileTypeIndex: 0)
                                    }
                                default:
                                    completion(.failure(NSError(domain: "VideoProcessor", code: 8, userInfo: [NSLocalizedDescriptionKey: "Export session ended with unknown status"])))
                                }
                            }
                        }
                    }
                } else {
                    // Current fileType not supported, try the next one
                    tryExport(presetsIndex: presetsIndex, fileTypeIndex: fileTypeIndex + 1)
                }
            } else {
                // Current preset not valid, try the next one
                tryExport(presetsIndex: presetsIndex + 1, fileTypeIndex: 0)
            }
        }
        
        // Start the export process
        tryExport(presetsIndex: 0, fileTypeIndex: 0)
    }
    
    private func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .mov: return "mov"
        case .mp4: return "mp4"
        case .m4v: return "m4v"
        default: return "mov"
        }
    }
    
    func createUniqueVideoPath(withExtension fileExtension: String) -> URL {
        let uniqueFileName = "outputVideo-\(UUID().uuidString).\(fileExtension)"
        let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        return tempDirectoryURL.appendingPathComponent(uniqueFileName)
    }
    
    
}

