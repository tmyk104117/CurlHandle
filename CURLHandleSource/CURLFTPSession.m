//
//  CURLFTPSession.m
//
//  Created by Mike Abdullah on 04/03/2012.
//  Copyright (c) 2012 Karelia Software. All rights reserved.
//

#import "CURLFTPSession.h"
#import "NSURLRequest+CURLHandle.h"

@implementation CURLFTPSession

#pragma mark Lifecycle

- (id)initWithRequest:(NSURLRequest *)request;
{
    NSParameterAssert(request);
    
    if (self = [self init])
    {
        if (![self validateRequest:request])
        {
            [self release]; return nil;
        }
        _request = [request copy];
        
        _handle = [[CURLHandle alloc] init];
        [_handle setDelegate:self];
        if (!_handle)
        {
            [self release];
            return nil;
        }
    }
    
    return self;
}

- (void)dealloc
{
    [_handle cancel];   // for good measure
    [_handle setDelegate:nil];
    [_handle release];
    [_request release];
    [_credential release];
    [_data release];
    
    [super dealloc];
}

#pragma mark Auth

- (void)useCredential:(NSURLCredential *)credential
{
    [_credential release]; _credential = [credential retain];
    
    NSString *user = [credential user];
    if (user)
    {
        [_handle setString:user forKey:CURLOPT_USERNAME];
        
        NSString *password = [credential password];
        if (password) [_handle setString:password forKey:CURLOPT_PASSWORD];
    }
}

#pragma mark Requests

@synthesize baseRequest = _request;
- (void)setBaseRequest:(NSURLRequest *)request;
{
    NSParameterAssert([self validateRequest:request]);
    
    request = [request copy];
    [_request release]; _request = request;
}

- (BOOL)validateRequest:(NSURLRequest *)request;
{
    NSString *scheme = [[request URL] scheme];
    return ([@"ftp" caseInsensitiveCompare:scheme] == NSOrderedSame || [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame);
}

- (NSMutableURLRequest *)newMutableRequestWithPath:(NSString *)path isDirectory:(BOOL)isDirectory;
{
    NSMutableURLRequest *request = [_request mutableCopy];
    if ([path length])  // nil/empty paths should only occur when trying to CWD to the home directory
    {
        // Special case: Root directory when _request is a pathless URL (e.g. ftp://example.com ) needs a second slash to tell Curl it's absolute
        //if ([path isEqualToString:@"/"]) path = @"//";
        
        if ([path isAbsolutePath])
        {
            // It turns out that to list root, you need a URL like ftp://example.com//./
            if ([path length] == 1) path = @"/.";
        }
        
        if (isDirectory)
        {
            if (![path hasSuffix:@"/"] || [path isEqualToString:@"/"])
            {
                path = [path stringByAppendingString:@"/"];
            }
        }
        else
        {
            while ([path hasSuffix:@"/"])
            {
                path = [path substringToIndex:[path length] - 1];
            }
        }
        
        [request setURL:[[self class] URLWithPath:path relativeToURL:[request URL]]];
    }
    
    return request;
}

#pragma mark Operations

- (BOOL)executeCustomCommands:(NSArray *)commands
                  inDirectory:(NSString *)directory
createIntermediateDirectories:(BOOL)createIntermediates
                        error:(NSError **)error;
{
    // Navigate to the directory
    // @"HEAD" => CURLOPT_NOBODY, which stops libcurl from trying to list the directory's contents
    // If the connection is already at that directory then curl wisely does nothing
    NSMutableURLRequest *request = [self newMutableRequestWithPath:directory isDirectory:YES];
    [request setHTTPMethod:@"HEAD"];
    [request curl_setCreateIntermediateDirectories:createIntermediates];
    
    // Custom commands once we're in the correct directory
    // CURLOPT_PREQUOTE does much the same thing, but sometimes runs the command twice in my testing
    [request curl_setPostTransferCommands:commands];
    
    
    BOOL result = [_handle loadRequest:request error:error];
    [request release];
    return result;
}

- (NSString *)homeDirectoryPath:(NSError **)error;
{
    // Deliberately want a request that should avoid doing any work
    NSMutableURLRequest *request = [_request mutableCopy];
    [request setURL:[NSURL URLWithString:@"/" relativeToURL:[request URL]]];
    [request setHTTPMethod:@"HEAD"];
    
    BOOL success = [_handle loadRequest:request error:error];
    [request release];
    
    if (success)
    {
        NSString *result = [_handle initialFTPPath];
        if (!result && error) *error = nil; // I don't how the request would succeed, and this then fail, but it might
        return result;
    }
    else
    {
        return nil;
    }
}

#pragma mark Discovering Directory Contents

- (void)enumerateContentsOfDirectoryAtPath:(NSString *)path usingBlock:(void (^)(NSDictionary *parsedResourceListing, NSError *error))block;
{
    if (!path) path = @".";
    
    _enumerationBlock = [block copy];
    _data = [[NSMutableData alloc] init];
    
    NSMutableURLRequest *request = [self newMutableRequestWithPath:path isDirectory:YES];
    _enumerationURL = [[request URL] copy];
    
    [NSURLConnection connectionWithRequest:request delegate:self];
    [request release];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
{
    if (!error) error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil];
    _enumerationBlock(nil, error);
    
    // Clean up
    [_enumerationBlock release]; _enumerationBlock = nil;
    [_enumerationURL release]; _enumerationURL = nil;
    [_data release]; _data = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    [[challenge sender] useCredential:_credential forAuthenticationChallenge:challenge];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
{
    [_data appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
{
    // Process the data to make a directory listing
    while (1)
    {
        CFDictionaryRef parsedDict = NULL;
        CFIndex bytesConsumed = CFFTPCreateParsedResourceListing(NULL,
                                                                 [_data bytes], [_data length],
                                                                 &parsedDict);
        
        if (bytesConsumed > 0)
        {
            // Make sure CFFTPCreateParsedResourceListing was able to properly
            // parse the incoming data
            if (parsedDict)
            {
                _enumerationBlock((NSDictionary *)parsedDict, nil);
                CFRelease(parsedDict);
            }
            
            [_data replaceBytesInRange:NSMakeRange(0, bytesConsumed) withBytes:NULL length:0];
        }
        else if (bytesConsumed < 0)
        {
            // error!
            NSDictionary *userInfo = [[NSDictionary alloc] initWithObjectsAndKeys:
                                      _enumerationURL, NSURLErrorFailingURLErrorKey,
                                      [_enumerationURL absoluteString], NSURLErrorFailingURLStringErrorKey,
                                      nil];
            
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotParseResponse userInfo:userInfo];
            [userInfo release];
            
            _enumerationBlock(nil, error);
            break;
        }
        else
        {
            _enumerationBlock(nil, nil);
            break;
        }
    }
    
    // Clean up
    [_enumerationBlock release]; _enumerationBlock = nil;
    [_enumerationURL release]; _enumerationURL = nil;
    [_data release]; _data = nil;
}

#pragma mark Creating and Deleting Items

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data withIntermediateDirectories:(BOOL)createIntermediates error:(NSError **)error;
{
    NSMutableURLRequest *request = [self newMutableRequestWithPath:path isDirectory:NO];
    [request setHTTPBody:data];
    [request curl_setCreateIntermediateDirectories:createIntermediates];
    
    BOOL result = [self createFileWithRequest:request error:error progressBlock:nil];
    [request release];
    
    return result;
}

- (BOOL)createFileAtPath:(NSString *)path withContentsOfURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates error:(NSError **)error progressBlock:(void (^)(NSUInteger bytesWritten))progressBlock;
{
    NSMutableURLRequest *request = [self newMutableRequestWithPath:path isDirectory:NO];
    
    // Read the data using an input stream if possible
    NSInputStream *stream = [[NSInputStream alloc] initWithURL:url];
    if (stream)
    {
        [request setHTTPBodyStream:stream];
        [stream release];
    }
    else
    {
        NSData *data = [[NSData alloc] initWithContentsOfURL:url options:0 error:error];
        if (data)
        {
            [request setHTTPBody:data];
            [data release];
        }
        else
        {
            [request release];
            return NO;
        }
    }
    
    [request curl_setCreateIntermediateDirectories:createIntermediates];
    
    BOOL result = [self createFileWithRequest:request error:error progressBlock:progressBlock];
    [request release];
    
    return result;
}

- (BOOL)createFileWithRequest:(NSURLRequest *)request error:(NSError **)outError progressBlock:(void (^)(NSUInteger bytesWritten))progressBlock;
{
    // Use our own progress block to watch for the file end being reached before passing onto the original requester
    __block BOOL atEnd = NO;
    _progressBlock = ^(NSUInteger bytesWritten){
        if (bytesWritten == 0) atEnd = YES;
        if (progressBlock) progressBlock(bytesWritten);
    };
    
    NSError *error;
    BOOL result = [_handle loadRequest:request error:&error];
    _progressBlock = NULL;
    
    
    // Long FTP uploads have a tendency to have the control connection cutoff for idling. As a hack, assume that if we reached the end of the body stream, a timeout is likely because of that
    if (!result)
    {
        if (atEnd && [error code] == NSURLErrorTimedOut && [[error domain] isEqualToString:NSURLErrorDomain])
        {
            return YES;
        }
        
        if (outError) *outError = error;
    }
    
    return result;
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates error:(NSError **)error;
{
    return [self executeCustomCommands:[NSArray arrayWithObject:[@"MKD " stringByAppendingString:[path lastPathComponent]]]
                           inDirectory:[path stringByDeletingLastPathComponent]
         createIntermediateDirectories:createIntermediates
                                 error:error];
}

- (BOOL)setAttributes:(NSDictionary *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error;
{
    NSParameterAssert(attributes);
    NSParameterAssert(path);
    
    NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
    if (permissions)
    {
        NSArray *commands = [NSArray arrayWithObject:[NSString stringWithFormat:
                                                      @"SITE CHMOD %lo %@",
                                                      [permissions unsignedLongValue],
                                                      [path lastPathComponent]]];
        
        BOOL result = [self executeCustomCommands:commands
                                      inDirectory:[path stringByDeletingLastPathComponent]
                    createIntermediateDirectories:NO
                                            error:error];
        
        if (!result) return NO;
    }
    
    return YES;
}

- (BOOL)removeFileAtPath:(NSString *)path error:(NSError **)error;
{
    return [self executeCustomCommands:[NSArray arrayWithObject:[@"DELE " stringByAppendingString:[path lastPathComponent]]]
                           inDirectory:[path stringByDeletingLastPathComponent]
         createIntermediateDirectories:NO
                                 error:error];
}

#pragma mark Cancellation

- (void)cancel; { [_handle cancel]; }

#pragma mark Delegate

@synthesize delegate = _delegate;

- (void)handle:(CURLHandle *)handle didReceiveData:(NSData *)data;
{
    [_data appendData:data];
}

- (void)handle:(CURLHandle *)handle willSendBodyDataOfLength:(NSUInteger)bytesWritten;
{
    if (_progressBlock)
    {
        _progressBlock(bytesWritten);
    }
}

- (void)handle:(CURLHandle *)handle didReceiveDebugInformation:(NSString *)string ofType:(curl_infotype)type;
{
    // Don't want to include password in transcripts usually!
    if (type == CURLINFO_HEADER_OUT &&
        [string hasPrefix:@"PASS"] &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"AllowPasswordToBeLogged"])
    {
        string = @"PASS ####";
    }
    
    [[self delegate] FTPSession:self didReceiveDebugInfo:string ofType:type];
}

#pragma mark FTP URL helpers

+ (NSURL *)URLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL;
{
    // FTP is special. Absolute paths need to specified with an extra prepended slash <http://curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTURL>
    NSString *scheme = [baseURL scheme];
    
    if (([@"ftp" caseInsensitiveCompare:scheme] == NSOrderedSame || [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame) &&
        [path isAbsolutePath])
    {
        // Get to host's URL, including single trailing slash
        // -absoluteURL has to be called so that the real path can be properly appended
        baseURL = [[NSURL URLWithString:@"/" relativeToURL:baseURL] absoluteURL];
        return [baseURL URLByAppendingPathComponent:path];
    }
    else
    {
        return [NSURL URLWithString:[path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]
                      relativeToURL:baseURL];
    }
}

+ (NSString *)pathOfURLRelativeToHomeDirectory:(NSURL *)URL;
{
    // FTP is special. The first slash of the path is to be ignored <http://curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTURL>
    NSString *scheme = [URL scheme];
    if ([@"ftp" caseInsensitiveCompare:scheme] == NSOrderedSame || [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame)
    {
        CFStringRef strictPath = CFURLCopyStrictPath((CFURLRef)[URL absoluteURL], NULL);
        NSString *result = [(NSString *)strictPath stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (strictPath) CFRelease(strictPath);
        return result;
    }
    else
    {
        return [URL path];
    }
}

@end
