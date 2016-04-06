// ImageCache.swift
//
// Copyright (c) 2015 Alamofire Software Foundation (http://alamofire.org/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

/**
*  这个AutoPurgingImageCache缓存只是做了内存缓存，没有磁盘缓存
*/

import Alamofire
import Foundation

#if os(iOS) || os(watchOS)
import UIKit
#elseif os(OSX)
import Cocoa
#endif

// MARK: ImageCache

/// The `ImageCache` protocol defines a set of APIs for adding, removing and fetching images from a cache.
public protocol ImageCache {
    /// Adds the image to the cache with the given identifier.
    func addImage(image: Image, withIdentifier identifier: String)

    /// Removes the image from the cache matching the given identifier.
    func removeImageWithIdentifier(identifier: String) -> Bool

    /// Removes all images stored in the cache.
    func removeAllImages() -> Bool

    /// Returns the image in the cache associated with the given identifier.
    func imageWithIdentifier(identifier: String) -> Image?
}

/// The `ImageRequestCache` protocol extends the `ImageCache` protocol by adding methods for adding, removing and
/// fetching images from a cache given an `NSURLRequest` and additional identifier.
public protocol ImageRequestCache: ImageCache {
    /// Adds the image to the cache using an identifier created from the request and additional identifier.
    func addImage(image: Image, forRequest request: NSURLRequest, withAdditionalIdentifier identifier: String?)

    /// Removes the image from the cache using an identifier created from the request and additional identifier.
    func removeImageForRequest(request: NSURLRequest, withAdditionalIdentifier identifier: String?) -> Bool

    /// Returns the image from the cache associated with an identifier created from the request and additional identifier.
    func imageForRequest(request: NSURLRequest, withAdditionalIdentifier identifier: String?) -> Image?
}

// MARK: -

/// The `AutoPurgingImageCache` in an in-memory image cache used to store images up to a given memory capacity. When 
/// the memory capacity is reached, the image cache is sorted by last access date, then the oldest image is continuously 
/// purged until the preferred memory usage after purge is met. Each time an image is accessed through the cache, the 
/// internal access date of the image is updated.
public class AutoPurgingImageCache: ImageRequestCache {
    private class CachedImage {
        let image: Image
        let identifier: String
        let totalBytes: UInt64
        ///  记录缓存这个图片的时间
        var lastAccessDate: NSDate

        init(_ image: Image, identifier: String) {
            self.image = image
            self.identifier = identifier
            self.lastAccessDate = NSDate()

            ///  计算image的大小
            self.totalBytes = {
                #if os(iOS) || os(watchOS)
                    let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
                #elseif os(OSX)
                    let size = CGSize(width: image.size.width, height: image.size.height)
                #endif
                // 这里难道是1个点等于4个像素？？
                let bytesPerPixel: CGFloat = 4.0
                let bytesPerRow = size.width * bytesPerPixel
                let totalBytes = UInt64(bytesPerRow) * UInt64(size.height)

                return totalBytes
            }()
        }

        func accessImage() -> Image {
            lastAccessDate = NSDate()
            return image
        }
    }

    // MARK: Properties

    /// The current total memory usage in bytes of all images stored within the cache.
    //  是存在在缓存中的数据，在内存中的大小？
    public var memoryUsage: UInt64 {
        var memoryUsage: UInt64 = 0
        dispatch_sync(synchronizationQueue) { memoryUsage = self.currentMemoryUsage }

        return memoryUsage
    }

    /// The total memory capacity of the cache in bytes.
    /// 缓存中允许内存容量的大小(单位字节)
    public let memoryCapacity: UInt64

    /// The preferred memory usage after purge in bytes. During a purge, images will be purged until the memory 
    /// capacity drops below this limit.
    ///  清除后首选的内容容量
    public let preferredMemoryUsageAfterPurge: UInt64
    ///  串行队列
    private let synchronizationQueue: dispatch_queue_t
    private var cachedImages: [String: CachedImage]
    ///  当前使用的内存大小
    private var currentMemoryUsage: UInt64

    // MARK: Initialization

    /**
        Initialies the `AutoPurgingImageCache` instance with the given memory capacity and preferred memory usage 
        after purge limit.

        - parameter memoryCapacity:                 The total memory capacity of the cache in bytes. `100 MB` by default.
        - parameter preferredMemoryUsageAfterPurge: The preferred memory usage after purge in bytes. `60 MB` by default.

        - returns: The new `AutoPurgingImageCache` instance.
    */
    public init(memoryCapacity: UInt64 = 100 * 1024 * 1024, preferredMemoryUsageAfterPurge: UInt64 = 60 * 1024 * 1024) {
        self.memoryCapacity = memoryCapacity
        self.preferredMemoryUsageAfterPurge = preferredMemoryUsageAfterPurge

        self.cachedImages = [:]
        self.currentMemoryUsage = 0

        self.synchronizationQueue = {
            let name = String(format: "com.alamofire.autopurgingimagecache-%08%08", arc4random(), arc4random())
            return dispatch_queue_create(name, DISPATCH_QUEUE_CONCURRENT)
        }()

        ///  为内存警告注册通知
        #if os(iOS)
            NSNotificationCenter.defaultCenter().addObserver(
                self,
                selector: "removeAllImages",
                name: UIApplicationDidReceiveMemoryWarningNotification,
                object: nil
            )
        #endif
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    // MARK: Add Image to Cache

    /**
        Adds the image to the cache using an identifier created from the request and optional identifier.

        - parameter image:      The image to add to the cache.
        - parameter request:    The request used to generate the image's unique identifier.
        - parameter identifier: The additional identifier to append to the image's unique identifier.
    */
    public func addImage(image: Image, forRequest request: NSURLRequest, withAdditionalIdentifier identifier: String? = nil) {
        let requestIdentifier = imageCacheKeyFromURLRequest(request, withAdditionalIdentifier: identifier)
        addImage(image, withIdentifier: requestIdentifier)
    }

    /**
        Adds the image to the cache with the given identifier.

        - parameter image:      The image to add to the cache.
        - parameter identifier: The identifier to use to uniquely identify the image.
    */
    public func addImage(image: Image, withIdentifier identifier: String) {
        // 使用dispatch_barrier_async控制顺序
        dispatch_barrier_async(synchronizationQueue) {
            ///  根据image和identifier创建CachedImage
            let cachedImage = CachedImage(image, identifier: identifier)
            ///  拿到以前的缓存，如果有替换成最新的
            if let previousCachedImage = self.cachedImages[identifier] {
                self.currentMemoryUsage -= previousCachedImage.totalBytes
            }
            ///  保存到字典
            self.cachedImages[identifier] = cachedImage
            ///  记录当前使用内存的大小
            self.currentMemoryUsage += cachedImage.totalBytes
        }

        dispatch_barrier_async(synchronizationQueue) {
            ///  如果当前存在内存中的大小大于总大小
            if self.currentMemoryUsage > self.memoryCapacity {
                ///  要清除缓存的大小
                let bytesToPurge = self.currentMemoryUsage - self.preferredMemoryUsageAfterPurge

                var sortedImages = [CachedImage](self.cachedImages.values)
                ///  按时间排序
                sortedImages.sortInPlace {
                    let date1 = $0.lastAccessDate
                    let date2 = $1.lastAccessDate
                    // 升序
                    return date1.timeIntervalSinceDate(date2) < 0.0
                }

                var bytesPurged = UInt64(0)
                
                for cachedImage in sortedImages {
                    self.cachedImages.removeValueForKey(cachedImage.identifier)
                    bytesPurged += cachedImage.totalBytes

                    if bytesPurged >= bytesToPurge {
                        break
                    }
                }

                self.currentMemoryUsage -= bytesPurged
            }
        }
    }

    // MARK: Remove Image from Cache

    /**
        Removes the image from the cache using an identifier created from the request and optional identifier.

        - parameter request:    The request used to generate the image's unique identifier.
        - parameter identifier: The additional identifier to append to the image's unique identifier.

        - returns: `true` if the image was removed, `false` otherwise.
    */
    public func removeImageForRequest(request: NSURLRequest, withAdditionalIdentifier identifier: String?) -> Bool {
        let requestIdentifier = imageCacheKeyFromURLRequest(request, withAdditionalIdentifier: identifier)
        return removeImageWithIdentifier(requestIdentifier)
    }

    /**
        Removes the image from the cache matching the given identifier.

        - parameter identifier: The unique identifier for the image.

        - returns: `true` if the image was removed, `false` otherwise.
    */
    public func removeImageWithIdentifier(identifier: String) -> Bool {
        var removed = false

        dispatch_barrier_async(synchronizationQueue) {
            if let cachedImage = self.cachedImages.removeValueForKey(identifier) {
                self.currentMemoryUsage -= cachedImage.totalBytes
                removed = true
            }
        }

        return removed
    }

    /**
        Removes all images stored in the cache.

        - returns: `true` if images were removed from the cache, `false` otherwise.
    */
    @objc public func removeAllImages() -> Bool {
        var removed = false

        dispatch_sync(synchronizationQueue) {
            if !self.cachedImages.isEmpty {
                self.cachedImages.removeAll()
                self.currentMemoryUsage = 0

                removed = true
            }
        }

        return removed
    }

    // MARK: Fetch Image from Cache

    /**
        Returns the image from the cache associated with an identifier created from the request and optional identifier.

        - parameter request:    The request used to generate the image's unique identifier.
        - parameter identifier: The additional identifier to append to the image's unique identifier.

        - returns: The image if it is stored in the cache, `nil` otherwise.
    */
    public func imageForRequest(request: NSURLRequest, withAdditionalIdentifier identifier: String? = nil) -> Image? {
        let requestIdentifier = imageCacheKeyFromURLRequest(request, withAdditionalIdentifier: identifier)
        return imageWithIdentifier(requestIdentifier)
    }

    /**
        Returns the image in the cache associated with the given identifier.

        - parameter identifier: The unique identifier for the image.

        - returns: The image if it is stored in the cache, `nil` otherwise.
    */
    public func imageWithIdentifier(identifier: String) -> Image? {
        var image: Image?

        dispatch_sync(synchronizationQueue) {
            if let cachedImage = self.cachedImages[identifier] {
                image = cachedImage.accessImage()
            }
        }
        return image
    }

    // MARK: Private - Helper Methods
    ///  根据Request和identifier创建字符串
    private func imageCacheKeyFromURLRequest(
        request: NSURLRequest,
        withAdditionalIdentifier identifier: String?)
        -> String
    {
        var key = request.URLString

        if let identifier = identifier {
            key += "-\(identifier)"
        }

        return key
    }
}
