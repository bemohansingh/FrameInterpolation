import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import Photos
// Import other necessary frameworks like a machine learning framework for motion estimation

class VideoProcessor {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var computePipelineState: MTLComputePipelineState!
    
    
    init() throws {
        // Initialize Metal device and command queue
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "VideoProcessor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this device"])
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Set up the compute pipeline with a Metal shader for frame interpolation
        guard let defaultLibrary = device.makeDefaultLibrary(),
              let kernelFunction = defaultLibrary.makeFunction(name: "frameInterpolationKernel") else {
            throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load the kernel function from the default library"])
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
                
                print("Extracted Frames")
                
                // Interpolate frames
                let interpolatedFrames = try self.interpolateFrames(frames)
                
                print("Interpolated Frames Completed")
               
                // Adjust frame rate
                let adjustedVideo = try self.adjustFrameRate(forVideo: video, withFrames: interpolatedFrames)
                print("Adjusted Frames Completed")
                completion(.success(adjustedVideo))

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }}
    private func adjustFrameRate(forVideo video: AVAsset, withFrames frames: [CGImage], targetFrameRate: Int = 60) throws -> AVAsset {
        // Create an AVMutableComposition to hold the new video frames
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create composition track"])
        }
        
        // Calculate frame duration based on the target frame rate
        let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        
        let videoTrack = video.tracks(withMediaType: .video)[0]
        let videoDuration = video.duration

        // Calculate the total number of frames needed for the new frame rate
        let totalFrames = Int(CMTimeGetSeconds(videoDuration) * Double(targetFrameRate))

        // Resize the frames array to match the total number of frames needed
        let resizedFrames = resizeFramesArray(frames, to: totalFrames)

        // Insert each frame into the composition
        var currentTime = CMTime.zero
        for frame in resizedFrames {
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

    private func resizeFramesArray(_ frames: [CGImage], to totalFrames: Int) -> [CGImage] {
        var resizedFrames = [CGImage]()
        let step = Double(frames.count) / Double(totalFrames)
        var index = 0.0

        for _ in 0..<totalFrames {
            resizedFrames.append(frames[min(Int(index), frames.count - 1)])
            index += step
        }

        return resizedFrames
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
        do {
            // Create an asset reader
            guard let assetReader = try? AVAssetReader(asset: video) else {
                throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAssetReader"])
            }
            print("Asset reader created successfully.")

            // Get the video track
            guard let videoTrack = video.tracks(withMediaType: .video).first else {
                throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video track available"])
            }
            print("Video track obtained.")

            // Configure reader output with the video track and settings
            let readerOutputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
            ]
            let assetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
            assetReader.add(assetReaderOutput)
            print("Reader output settings configured.")

            // Start reading
            assetReader.startReading()
            print("Asset reader started reading.")

            // Read the samples from the video track
            while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer(), CMSampleBufferIsValid(sampleBuffer) {
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                print("Sample buffer obtained.")

                // Create a CIImage from the CVPixelBuffer
                let ciImage = CIImage(cvPixelBuffer: imageBuffer)

                // Convert CIImage to CGImage
                let context = CIContext(options: nil)
                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                    frames.append(cgImage)
                    print("CGImage created and added to frames.")
                }
            }

            if assetReader.status == .failed {
                throw assetReader.error ?? NSError(domain: "VideoProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Asset reader failed to read video track."])
            }

            print("Frames extraction completed. Total frames extracted: \(frames.count)")
        } catch {
            print("Error during frame extraction: \(error)")
            throw error
        }

        return frames
    }
    
    
    private func interpolateFrames(_ frames: [CGImage]) throws -> [CGImage] {
        var interpolatedFrames: [CGImage] = []

        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this device"])
            }
            print("Metal device created.")

            guard let commandQueue = device.makeCommandQueue() else {
                throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
            }
            print("Command queue created.")

            let computePipelineState = try self.makeComputePipelineState(device: device)
            print("Compute pipeline state created.")

            for i in 0..<frames.count - 1 {
                let currentTexture = try self.makeTexture(from: frames[i], device: device)
                let nextTexture = try self.makeTexture(from: frames[i + 1], device: device)
                let outputTexture = try self.makeEmptyTexture(matching: currentTexture, device: device)
                print("Textures prepared for frame index \(i).")

                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                      let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw NSError(domain: "VideoProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer or encoder"])
                }
                print("Command buffer and encoder created.")

                commandEncoder.setComputePipelineState(computePipelineState)
                commandEncoder.setTexture(currentTexture, index: 0)
                commandEncoder.setTexture(nextTexture, index: 1)
                commandEncoder.setTexture(outputTexture, index: 2)

                let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let threadgroupCount = MTLSize(width: (currentTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                                               height: (currentTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                                               depth: 1)

                commandEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
                commandEncoder.endEncoding()
                print("Encoding completed for frame index \(i).")

                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                if let cgImage = try convertTextureToCGImage(outputTexture) {
                    interpolatedFrames.append(cgImage)
                    print("Interpolated frame added, total count: \(interpolatedFrames.count)")
                }
            }
            print("Interpolation of all frames completed.")
        } catch {
            print("Failed to interpolate frames: \(error)")
            throw error
        }

        return interpolatedFrames
    }
    

    private func makeComputePipelineState(device: MTLDevice) throws -> MTLComputePipelineState {
        do {
            guard let defaultLibrary = device.makeDefaultLibrary() else {
                print("Error: Could not get the default library.")
                throw NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get the default library"])
            }
            print("Default library obtained successfully.")

            guard let kernelFunction = defaultLibrary.makeFunction(name: "interpolationKernel") else {
                print("Error: Kernel function 'interpolationKernel' not found in the library.")
                throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kernel function 'interpolationKernel' not found"])
            }
            print("Kernel function 'interpolationKernel' found in the library.")

            let computePipelineState = try device.makeComputePipelineState(function: kernelFunction)
            print("Compute pipeline state created successfully.")
            return computePipelineState

        } catch {
            print("Failed to create compute pipeline state: \(error.localizedDescription)")
            throw error
        }
    }

    
    
    private func makeTexture(from cgImage: CGImage, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: cgImage.width,
                                                                  height: cgImage.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("Error: Failed to create texture from CGImage.")
            throw NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        print("Texture created successfully.")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: cgImage.width,
                                      height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4 * cgImage.width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("Error: Failed to create CGContext for texture.")
            throw NSError(domain: "VideoProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        let region = MTLRegionMake2D(0, 0, cgImage.width, cgImage.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: context.data!, bytesPerRow: 4 * cgImage.width)
        
        print("Texture data set successfully.")
        return texture
    }

    
    private func makeEmptyTexture(matching texture: MTLTexture, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                                  width: texture.width,
                                                                  height: texture.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            print("Error: Failed to create empty texture matching the given texture.")
            throw NSError(domain: "VideoProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
        }
        print("Empty texture created successfully.")
        return newTexture
    }
    
    
    
    
    
    private func convertTextureToCGImage(_ texture: MTLTexture) throws -> CGImage? {
        let width = texture.width
        let height = texture.height
        print("Converting texture to CGImage. Width: \(width), Height: \(height)")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rawData = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 1)
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
            print("Texture successfully converted to CGImage.")
            return cgImage
        } else {
            print("Failed to convert texture to CGImage.")
            return nil
        }
    }
    
    private func createPixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        print("Creating pixel buffer from CGImage. Width: \(width), Height: \(height)")

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)

        guard status == kCVReturnSuccess, let unwrappedBuffer = pixelBuffer else {
            print("Error: Unable to create CVPixelBuffer.")
            throw NSError(domain: "VideoProcessor", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to create CVPixelBuffer"])
        }

        CVPixelBufferLockBaseAddress(unwrappedBuffer, [])
        let pixelData = CVPixelBufferGetBaseAddress(unwrappedBuffer)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(unwrappedBuffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            print("Error: Unable to create CGContext.")
            CVPixelBufferUnlockBaseAddress(unwrappedBuffer, [])
            throw NSError(domain: "VideoProcessor", code: 9, userInfo: [NSLocalizedDescriptionKey: "Unable to create CGContext"])
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(unwrappedBuffer, [])
        print("Pixel buffer successfully created from CGImage.")
        return unwrappedBuffer
    }
    
    
     func outputVideo(_ video: AVAsset, completion: @escaping (Result<String, Error>) -> Void) {
        // Check photo library access
        let status = PHPhotoLibrary.authorizationStatus()
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization { newStatus in
                if newStatus == .authorized {
                    print("Read/ Write Permission is Authorised")
                    self.loadAndExportVideo(video, completion: completion)
                } else {
                    print("Read/ Write Permission is Denied")
                    completion(.failure(NSError(domain: "VideoProcessor", code: 13, userInfo: [NSLocalizedDescriptionKey: "Photo Library access denied"])))
                }
            }
        } else if status == .authorized {
            self.loadAndExportVideo(video, completion: completion)
        } else {
            completion(.failure(NSError(domain: "VideoProcessor", code: 13, userInfo: [NSLocalizedDescriptionKey: "Photo Library access denied"])))
        }
    }
    
    
    private func loadAndExportVideo(_ video: AVAsset, completion: @escaping (Result<String, Error>) -> Void) {
        // Load the isExportable property
        let key = #keyPath(AVAsset.isExportable)
        video.loadValuesAsynchronously(forKeys: [key]) {
            var error: NSError? = nil
            let status = video.statusOfValue(forKey: key, error: &error)

            DispatchQueue.main.async {
                switch status {
                case .loaded:
                    if video.isExportable {
                        print("The given AV Asset is Exportable")
                        self.checkAssetIntegrity(asset: video) { isIntact in
                            if isIntact {
                                print("The given AVAsset is playable")
                                self.continueExportProcess(video: video, completion: completion)
                            } else {
                                completion(.failure(NSError(domain: "VideoProcessor", code: 10, userInfo: [NSLocalizedDescriptionKey: "Asset is not exportable"])))
                            }
                        }
                    } else {
                        completion(.failure(NSError(domain: "VideoProcessor", code: 10, userInfo: [NSLocalizedDescriptionKey: "Asset is not exportable"])))
                    }
                case .failed, .cancelled:
                    completion(.failure(error ?? NSError(domain: "VideoProcessor", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"])))
                default:
                    completion(.failure(NSError(domain: "VideoProcessor", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unknown error occurred while loading asset properties"])))
                }
            }
        }
    }
    
    func checkAssetIntegrity(asset: AVAsset, completion: @escaping (Bool) -> Void) {
        let keys = ["playable", "tracks"]

        asset.loadValuesAsynchronously(forKeys: keys) {
            var isAssetPlayable = true

            for key in keys {
                var error: NSError?
                let status = asset.statusOfValue(forKey: key, error: &error)
                if status == .failed || status == .cancelled {
                    isAssetPlayable = false
                    break
                }
            }

            if !asset.isPlayable || !isAssetPlayable {
                completion(false)
            } else {
                completion(true)
            }
        }
    }
    
    
    private func continueExportProcess(video: AVAsset, completion: @escaping (Result<String, Error>) -> Void) {
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
                    try? FileManager.default.removeItem(at: outputURL)
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = fileType

                    exportSession.exportAsynchronously {
                        DispatchQueue.main.async {
                            switch exportSession.status {
                            case .completed:
                                completion(.success(outputURL.path))
                            case .failed, .cancelled:
        
                                if let error = exportSession.error {
                                                             print("Export failed with preset \(preset) and fileType \(fileType.rawValue): \(error.localizedDescription)")
                                                         } else {
                                                             print("Export failed with preset \(preset) and fileType \(fileType.rawValue): Unknown error")
                                                         }
                                
                                
                                
                                // Try the next fileType or preset
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
