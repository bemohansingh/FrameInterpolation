//
//  ViewController.swift
//  Frame
//
//  Created by Mohan Singh Thagunna on 30/12/2023.
//

import UIKit
import Photos
import AVKit

class ViewController: UIViewController {

    @IBOutlet weak var originalView: UIView!
    
    @IBOutlet weak var convetertedView: UIView!
    var processor: VideoProcessor!
    var playerViewController: AVPlayerViewController?
    var asset: AVAsset?
    
    var player: AVPlayer?
    var playerLayer: AVPlayerLayer?
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    @IBAction func loadVideo(_ sender: Any) {
        self.pickVideo()

    }
    @IBAction func exportVideo(_ sender: Any) {
        if let asset = self.asset {
            if let urlAsset = asset as? AVURLAsset {
                saveVideoToLibrary(videoURL: urlAsset.url)
               } else {
                   processor?.outputVideo(asset, completion: { result in
                       switch result {
                       case .success(let res):
                           self.saveVideoToLibrary(videoURL: URL(string: res)!)
                           print("success \(res)")
                       case .failure(let error):
                           print("error \(error)")
                       }
                   })
                  print("INVALID ASSET")
               }
          
        }
    }
    
    @IBAction func playVideo(_ sender: Any) {
        playVideo()
    }
    func playVideo() {
        if let asset = self.asset {
            DispatchQueue.main.async {
                let playerItem = AVPlayerItem(asset: asset)
                self.player = AVPlayer(playerItem: playerItem)

                self.playerLayer = AVPlayerLayer(player: self.player)
                self.playerLayer?.frame = self.convetertedView.bounds
                self.playerLayer?.videoGravity = .resizeAspectFill

                self.convetertedView.layer.addSublayer(self.playerLayer!)
                self.player?.play()
            }
        }
    }
    
}


extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate  {
    func pickVideo() {
        let imagePicker = UIImagePickerController()
        imagePicker.sourceType = .photoLibrary
        imagePicker.mediaTypes = ["public.movie"]
        imagePicker.delegate = self
        present(imagePicker, animated: true, completion: nil)
    }
    
   
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        if let videoURL = info[.mediaURL] as? URL {
            // Handle the selected video URL
            print("Selected video URL: \(videoURL)")
            do {
                 processor = try VideoProcessor()
                processor.processVideo(atPath: videoURL) { result in
                    switch result {
                    case .success(let video):
                        self.asset = video
                        self.playVideo()
                        print(video)
                        break;
                    case .failure(let error):
                        print(error)
                    }
                }
            } catch {
                print("error=======================")
                print("error=======================")
                print("error=======================")
                print(error)
            }
          
            
        }
        
        picker.dismiss(animated: true, completion: nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
}

extension ViewController {
    func saveVideoToLibrary(videoURL: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                    request?.creationDate = Date()
                } completionHandler: { success, error in
                    if success {
                        print("Video saved successfully.")
                    } else {
                        print("Error saving video: \(error?.localizedDescription ?? "Unknown error")")
                    }
                }
            } else {
                print("Permission to access photo library denied.")
            }
        }
    }
    
 
}
