//
// SPDX-License-Identifier: MIT
//
// Part of https://github.com/sbooth/SFBAudioEngine
//

#import "SFBHTTPInputSource.h"
#import "SFBInputSource+Internal.h"

@interface SFBHTTPInputSource () <NSURLSessionDataDelegate> {
  @private
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSCondition *_cond;
    NSMutableData *_buffer;      // bytes received starting at _baseOffset
    NSInteger _baseOffset;       // absolute file offset of _buffer[0]
    NSInteger _pos;              // absolute read offset
    long long _totalLength;      // -1 until known
    BOOL _gotResponse;
    BOOL _complete;
    BOOL _failed;
}
@end

@implementation SFBHTTPInputSource

- (instancetype)initWithURL:(NSURL *)url {
    NSParameterAssert(url != nil);
    if ((self = [super initWithURL:url])) {
        _cond = [NSCondition new];
        _totalLength = -1;
    }
    return self;
}

- (void)_startTaskFrom:(NSInteger)offset {
    _buffer = [NSMutableData data];
    _baseOffset = offset;
    _pos = offset;
    _gotResponse = NO;
    _complete = NO;
    _failed = NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self->_url];
    if (offset > 0)
        [request setValue:[NSString stringWithFormat:@"bytes=%ld-", (long)offset]
       forHTTPHeaderField:@"Range"];
    if (!_session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    _task = [_session dataTaskWithRequest:request];
    [_task resume];
}

- (BOOL)openReturningError:(NSError **)error {
    [self _startTaskFrom:0];
    // Wait for the response so the length is known (decoders ask early).
    [_cond lock];
    while (!_gotResponse && !_failed && !_complete)
        [_cond wait];
    BOOL ok = !_failed;
    [_cond unlock];
    if (!ok && error)
        *error = [self posixErrorWithCode:EIO];
    return ok;
}

- (BOOL)closeReturningError:(NSError **)error {
    [_cond lock];
    [_task cancel];
    _task = nil;
    _buffer = nil;
    [_cond signal];
    [_cond unlock];
    [_session invalidateAndCancel];
    _session = nil;
    return YES;
}

- (BOOL)isOpen {
    return _session != nil;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    NSParameterAssert(buffer != NULL);
    NSParameterAssert(length >= 0);
    NSParameterAssert(bytesRead != NULL);

    [_cond lock];
    NSInteger rel = _pos - _baseOffset;
    // Block until `length` bytes are buffered at the read point, or the
    // download finished (partial/EOF), or it failed.
    while (!_failed) {
        NSInteger available = (NSInteger)_buffer.length - rel;
        if (available >= length || _complete)
            break;
        [_cond wait];
    }
    if (_failed) {
        [_cond unlock];
        if (error) *error = [self posixErrorWithCode:EIO];
        return NO;
    }
    NSInteger available = (NSInteger)_buffer.length - rel;
    NSInteger count = MIN(length, MAX((NSInteger)0, available));
    if (count > 0)
        [_buffer getBytes:buffer range:NSMakeRange((NSUInteger)rel, (NSUInteger)count)];
    _pos += count;
    *bytesRead = count;
    [_cond unlock];
    return YES;
}

- (BOOL)atEOF {
    [_cond lock];
    BOOL eof;
    if (_totalLength >= 0)
        eof = _pos >= _totalLength;
    else
        eof = _complete && (_pos - _baseOffset) >= (NSInteger)_buffer.length;
    [_cond unlock];
    return eof;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    NSParameterAssert(offset != NULL);
    [_cond lock];
    *offset = _pos;
    [_cond unlock];
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    NSParameterAssert(length != NULL);
    [_cond lock];
    long long total = _totalLength;
    [_cond unlock];
    if (total < 0) {
        if (error) *error = [self posixErrorWithCode:ESPIPE];
        return NO;
    }
    *length = (NSInteger)total;
    return YES;
}

- (BOOL)supportsSeeking {
    return YES;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    NSParameterAssert(offset >= 0);
    [_cond lock];
    NSInteger bufStart = _baseOffset;
    NSInteger bufEnd = _baseOffset + (NSInteger)_buffer.length;
    if (offset >= bufStart && offset <= bufEnd) {
        _pos = offset;              // already buffered — instant
        [_cond unlock];
        return YES;
    }
    // Outside the buffer: restart the transfer with a Range request. Cancel the
    // old task first; its late callbacks are ignored because the buffer/base
    // are reset under the lock.
    [_task cancel];
    _task = nil;
    [_cond unlock];
    [self _startTaskFrom:offset];
    [_cond lock];
    while (!_gotResponse && !_failed && !_complete)
        [_cond wait];
    BOOL ok = !_failed;
    [_cond unlock];
    return ok;
}

// MARK: - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
                                didReceiveResponse:(NSURLResponse *)response
                                 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [_cond lock];
    if (dataTask == _task) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            // "Content-Range: bytes start-end/total" gives the whole-file size;
            // otherwise Content-Length + the range start we asked for.
            NSString *contentRange = http.allHeaderFields[@"Content-Range"];
            NSRange slash = contentRange ? [contentRange rangeOfString:@"/"] : NSMakeRange(NSNotFound, 0);
            if (slash.location != NSNotFound) {
                _totalLength = [[contentRange substringFromIndex:slash.location + 1] longLongValue];
            } else if (response.expectedContentLength != NSURLResponseUnknownLength) {
                _totalLength = _baseOffset + response.expectedContentLength;
            }
        }
        _gotResponse = YES;
        [_cond signal];
    }
    [_cond unlock];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
                                    didReceiveData:(NSData *)data {
    [_cond lock];
    if (dataTask == _task) {
        [_buffer appendData:data];
        [_cond signal];
    }
    [_cond unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
                            didCompleteWithError:(NSError *)error {
    [_cond lock];
    if (task == _task) {
        if (error && error.code != NSURLErrorCancelled)
            _failed = YES;
        _complete = YES;
        [_cond signal];
    }
    [_cond unlock];
}

@end
