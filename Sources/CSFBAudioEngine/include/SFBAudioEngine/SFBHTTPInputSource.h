//
// SPDX-License-Identifier: MIT
//
// Part of https://github.com/sbooth/SFBAudioEngine
//

#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// An input source that streams an HTTP(S) URL progressively via NSURLSession,
/// so a decoder can start before the whole file has arrived. Seeking uses HTTP
/// Range requests. All read/seek state is guarded so the (blocking) reads on
/// the decode thread coordinate with the network delegate.
NS_SWIFT_NAME(HTTPInputSource)
@interface SFBHTTPInputSource : SFBInputSource
/// - parameter url: An http:// or https:// URL (auth, if any, must be in the URL)
- (instancetype)initWithURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
