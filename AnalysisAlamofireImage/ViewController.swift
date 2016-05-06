//
//  ViewController.swift
//  AnalysisAlamofireImage
//
//  Created by WangZHW on 16/3/31.
//  Copyright © 2016年 RobuSoft. All rights reserved.
//

import UIKit
import AlamofireImage


class ViewController: UIViewController {

    @IBOutlet weak var imgOne: UIImageView!
    @IBOutlet weak var imgTwo: UIImageView!
    @IBOutlet weak var imgThree: UIImageView!
    private let synchronizationQueue: dispatch_queue_t = {
        let name = String(format: "synchronizationqueue-%08%08", arc4random(), arc4random())
        return dispatch_queue_create(name, DISPATCH_QUEUE_SERIAL)
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        let filter = AspectScaledToFillSizeCircleFilter(size: CGSizeMake(128, 128))
        self.imgOne.af_setImageWithURL(NSURL(string: "http://weicai-hearsay-avatar.qiniudn.com/b4f71f05a1b7593e05e91b0175bd7c9e?imageView2/2/w/192/h/277")!,
            placeholderImage: nil,
            filter: filter,
            imageTransition: UIImageView.ImageTransition.CrossDissolve(0.25))
            { (request, response, result) -> Void in
        }
        
        
//        dispatch_async(<#T##queue: dispatch_queue_t##dispatch_queue_t#>, <#T##block: dispatch_block_t##dispatch_block_t##() -> Void#>)
    }

    @IBAction func showTowImage(sender: AnyObject) {
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

