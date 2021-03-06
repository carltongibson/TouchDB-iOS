//
//  TDRouter.m
//  TouchDB
//
//  Created by Jens Alfke on 11/30/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDRouter.h"
#import "TDDatabase+Insertion.h"
#import "TDServer.h"
#import "TDView.h"
#import "TDBody.h"
#import "TDMultipartWriter.h"
#import "TDReplicatorManager.h"
#import "TDInternal.h"
#import <objc/message.h>


extern double TouchDBVersionNumber; // Defined in generated TouchDB_vers.c


@implementation TDRouter


+ (NSString*) versionString {
    return $sprintf(@"%g", TouchDBVersionNumber);
}


- (id) initWithServer: (TDServer*)server request: (NSURLRequest*)request {
    NSParameterAssert(server);
    NSParameterAssert(request);
    self = [super init];
    if (self) {
        _server = [server retain];
        _request = [request retain];
        _response = [[TDResponse alloc] init];
        if (0) { // assignments just to appease static analyzer so it knows these ivars are used
            _longpoll = NO;
            _changesIncludeDocs = NO;
        }
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_server release];
    [_request release];
    [_response release];
    [_queries release];
    [_path release];
    [_db release];
    [_changesFilter release];
    [_onResponseReady release];
    [_onDataAvailable release];
    [_onFinished release];
    [super dealloc];
}


@synthesize onResponseReady=_onResponseReady, onDataAvailable=_onDataAvailable,
            onFinished=_onFinished, request=_request, response=_response;


- (NSDictionary*) queries {
    if (!_queries) {
        NSString* queryString = _request.URL.query;
        if (queryString.length > 0) {
            NSMutableDictionary* queries = $mdict();
            for (NSString* component in [queryString componentsSeparatedByString: @"&"]) {
                NSRange equals = [component rangeOfString: @"="];
                if (equals.length == 0)
                    equals.location = component.length;
                NSString* key = [component substringToIndex: equals.location];
                NSString* value = [component substringFromIndex: NSMaxRange(equals)];
                [queries setObject: value forKey: key];
            }
            _queries = [queries copy];
        }
    }
    return _queries;
}


- (NSString*) query: (NSString*)param {
    return [[self.queries objectForKey: param]
                    stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
}

- (BOOL) boolQuery: (NSString*)param {
    NSString* value = [self query: param];
    return value && !$equal(value, @"false") && !$equal(value, @"0");
}

- (int) intQuery: (NSString*)param defaultValue: (int)defaultValue {
    NSString* value = [self query: param];
    return value ? value.intValue : defaultValue;
}

- (id) jsonQuery: (NSString*)param error: (NSError**)outError {
    if (outError)
        *outError = nil;
    NSString* value = [self query: param];
    if (!value)
        return nil;
    id result = [NSJSONSerialization
                            JSONObjectWithData: [value dataUsingEncoding: NSUTF8StringEncoding]
                                       options: NSJSONReadingAllowFragments error: outError];
    if (!result)
        Warn(@"TDRouter: invalid JSON in query param ?%@=%@", param, value);
    return result;
}


- (BOOL) cacheWithEtag: (NSString*)etag {
    NSString* eTag = $sprintf(@"\"%@\"", etag);
    [_response setValue: eTag ofHeader: @"Etag"];
    return $equal(eTag, [_request valueForHTTPHeaderField: @"If-None-Match"]);
}


- (NSDictionary*) bodyAsDictionary {
    return $castIf(NSDictionary, [NSJSONSerialization JSONObjectWithData: _request.HTTPBody
                                                                 options: 0 error: nil]);
}


- (TDContentOptions) contentOptions {
    TDContentOptions options = 0;
    if ([self boolQuery: @"attachments"])
        options |= kTDIncludeAttachments;
    if ([self boolQuery: @"local_seq"])
        options |= kTDIncludeLocalSeq;
    if ([self boolQuery: @"conflicts"])
        options |= kTDIncludeConflicts;
    if ([self boolQuery: @"revs"])
        options |= kTDIncludeRevs;
    if ([self boolQuery: @"revs_info"])
        options |= kTDIncludeRevsInfo;
    return options;
}


- (BOOL) getQueryOptions: (TDQueryOptions*)options {
    // http://wiki.apache.org/couchdb/HTTP_view_API#Querying_Options
    *options = kDefaultTDQueryOptions;
    options->skip = [self intQuery: @"skip" defaultValue: options->skip];
    options->limit = [self intQuery: @"limit" defaultValue: options->limit];
    options->groupLevel = [self intQuery: @"group_level" defaultValue: options->groupLevel];
    options->descending = [self boolQuery: @"descending"];
    options->includeDocs = [self boolQuery: @"include_docs"];
    options->updateSeq = [self boolQuery: @"update_seq"];
    if ([self query: @"inclusive_end"])
        options->inclusiveEnd = [self boolQuery: @"inclusive_end"];
    options->reduce = [self boolQuery: @"reduce"];
    options->group = [self boolQuery: @"group"];
    options->content = [self contentOptions];
    NSError* error = nil;
    options->startKey = [self jsonQuery: @"startkey" error: &error];
    if (error)
        return NO;
    options->endKey = [self jsonQuery: @"endkey" error: &error];
    if (error)
        return NO;
    id key = [self jsonQuery: @"key" error: &error];
    if (error)
        return NO;
    if (key)
        options->keys = $array(key);
    return YES;
}


- (NSString*) multipartRequestType {
    NSString* accept = [_request valueForHTTPHeaderField: @"Accept"];
    if ([accept hasPrefix: @"multipart/"])
        return accept;
    return nil;
}


- (TDStatus) openDB {
    // As a special case, the _replicator db is created on demand (as though it already existed)
    if (!_db.exists && !$equal(_db.name, kTDReplicatorDatabaseName))
        return 404;
    if (![_db open])
        return 500;
    return 200;
}


static NSArray* splitPath( NSURL* url ) {
    // Unfortunately can't just call url.path because that converts %2F to a '/'.
    NSString* pathString = NSMakeCollectable(CFURLCopyPath((CFURLRef)url));
    NSMutableArray* path = $marray();
    for (NSString* comp in [pathString componentsSeparatedByString: @"/"]) {
        if ([comp length] > 0) {
            comp = [comp stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            if (!comp) {
                path = nil;     // bad URL
                break;
            }
            [path addObject: comp];
        }
    }
    [pathString release];
    return path;
}


- (void) sendResponse {
    if (!_responseSent) {
        _responseSent = YES;
        if (_onResponseReady)
            _onResponseReady(_response);
    }
}


- (TDStatus) route {
    // Refer to: http://wiki.apache.org/couchdb/Complete_HTTP_API_Reference
    
    // We're going to map the request into a selector based on the method and path.
    // Accumulate the selector into the string 'message':
    NSString* method = _request.HTTPMethod;
    if ($equal(method, @"HEAD"))
        method = @"GET";
    NSMutableString* message = [NSMutableString stringWithFormat: @"do_%@", method];
    
    // First interpret the components of the request:
    _path = [splitPath(_request.URL) mutableCopy];
    if (!_path)
        return 400;
        
    NSUInteger pathLen = _path.count;
    if (pathLen > 0) {
        NSString* dbName = [_path objectAtIndex: 0];
        if ([dbName hasPrefix: @"_"] && ![TDServer isValidDatabaseName: dbName]) {
            [message appendString: dbName]; // special root path, like /_all_dbs
        } else {
            _db = [[_server databaseNamed: dbName] retain];
            if (!_db)
                return 400;
            [message appendString: @":"];
        }
    } else {
        [message appendString: @"Root"];
    }
    
    NSString* docID = nil;
    if (_db && pathLen > 1) {
        // Make sure database exists, then interpret doc name:
        TDStatus status = [self openDB];
        if (status >= 300)
            return status;
        NSString* name = [_path objectAtIndex: 1];
        if (![name hasPrefix: @"_"]) {
            // Regular document
            if (![TDDatabase isValidDocumentID: name])
                return 400;
            docID = name;
        } else if ([name isEqualToString: @"_design"] || [name isEqualToString: @"_local"]) {
            // "_design/____" and "_local/____" are document names
            if (pathLen <= 2)
                return 404;
            docID = [name stringByAppendingPathComponent: [_path objectAtIndex: 2]];
            [_path replaceObjectAtIndex: 1 withObject: docID];
            [_path removeObjectAtIndex: 2];
            --pathLen;
        } else if ([name hasPrefix: @"_design/"] || [name hasPrefix: @"_local/"]) {
            // This is also a document, just with a URL-encoded "/"
            docID = name;
        } else {
            // Special document name like "_all_docs":
            [message insertString: name atIndex: message.length-1]; // add to 1st component of msg
            if (pathLen > 2)
                docID = [[_path subarrayWithRange: NSMakeRange(2, _path.count-2)]
                         componentsJoinedByString: @"/"];
        }

        if (docID)
            [message appendString: @"docID:"];
    }
    
    NSString* attachmentName = nil;
    if (docID && pathLen > 2) {
        // Interpret attachment name:
        attachmentName = [_path objectAtIndex: 2];
        if ([attachmentName hasPrefix: @"_"] && [docID hasPrefix: @"_design/"]) {
            // Design-doc attribute like _info or _view
            [message replaceOccurrencesOfString: @":docID:" withString: @":designDocID:"
                                        options:0 range: NSMakeRange(0, message.length)];
            docID = [docID substringFromIndex: 8];  // strip the "_design/" prefix
            [message appendString: [attachmentName substringFromIndex: 1]];
            [message appendString: @":"];
            attachmentName = pathLen > 3 ? [_path objectAtIndex: 3] : nil;
        } else {
            [message appendString: @"attachment:"];
            if (pathLen > 3)
                attachmentName = [[_path subarrayWithRange: NSMakeRange(2, _path.count-2)]
                                                                componentsJoinedByString: @"/"];
        }
    }
    
    // Send myself a message based on the components:
    SEL sel = NSSelectorFromString(message);
    if (!sel || ![self respondsToSelector: sel]) {
        Log(@"TDRouter: unknown request type: %@ %@ (mapped to %@)",
             _request.HTTPMethod, _request.URL.path, message);
        Assert([self respondsToSelector: @selector(do_GETRoot)],
               @"TDRouter(Handlers) is missing -- app may be linked without -ObjC linker flag.");
        sel = @selector(do_UNKNOWN);
    }
    return (TDStatus) objc_msgSend(self, sel, _db, docID, attachmentName);
}


- (void) start {
    // Call the appropriate handler method:
    TDStatus status = [self route];

    // Configure response headers:
    if (status < 300 && !_response.body && ![_response.headers objectForKey: @"Content-Type"]) {
        _response.body = [TDBody bodyWithJSON: [@"{\"ok\":true}" dataUsingEncoding: NSUTF8StringEncoding]];
    }
    if (_response.body.isValidJSON)
        [_response setValue: @"application/json" ofHeader: @"Content-Type"];
    
    // Check for a mismatch between the Accept request header and the response type:
    NSString* accept = [_request valueForHTTPHeaderField: @"Accept"];
    if (accept && !$equal(accept, @"*/*")) {
        NSString* responseType = _response.baseContentType;
        if (responseType && [accept rangeOfString: responseType].length == 0) {
            LogTo(TDRouter, @"Error 406: Can't satisfy request Accept: %@", accept);
            status = 406;
            _response.headers = [NSMutableDictionary dictionary];
            _response.body = nil;
        }
    }

    [_response.headers setObject: $sprintf(@"TouchDB %g", TouchDBVersionNumber)
                          forKey: @"Server"];

    // If response is ready (nonzero status), tell my client about it:
    if (status > 0) {
        _response.status = status;
        [self sendResponse];
        if (_onDataAvailable && _response.body) {
            _onDataAvailable(_response.body.asJSON, !_waiting);
        }
        if (_onFinished && !_waiting)
            _onFinished();
    }
}


- (void) stop {
    self.onResponseReady = nil;
    self.onDataAvailable = nil;
    self.onFinished = nil;
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (void) startAsync {
    [_server queue:^{ [self start]; }];
}


- (TDStatus) do_UNKNOWN {
    return 400;
}


@end


#pragma mark - TDRESPONSE

@implementation TDResponse

- (id) init
{
    self = [super init];
    if (self) {
        _status = 200;
        _headers = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_headers release];
    [_body release];
    [super dealloc];
}

@synthesize status=_status, headers=_headers, body=_body;

- (void) setValue: (NSString*)value ofHeader: (NSString*)header {
    [_headers setValue: value forKey: header];
}

- (NSString*) baseContentType {
    NSString* type = [_headers objectForKey: @"Content-Type"];
    if (!type)
        return nil;
    NSRange r = [type rangeOfString: @";"];
    if (r.length > 0)
        type = [type substringToIndex: r.location];
    return type;
}

- (id) bodyObject {
    return self.body.asObject;
}

- (void) setBodyObject:(id)bodyObject {
    self.body = bodyObject ? [TDBody bodyWithProperties: bodyObject] : nil;
}

- (void) setMultipartBody: (NSArray*)parts type: (NSString*)type {
    TDMultipartWriter* mp = [[TDMultipartWriter alloc] initWithContentType: type
                                                                  boundary: nil];
    for (id part in parts) {
        if (![part isKindOfClass: [NSData class]]) {
            part = [NSJSONSerialization dataWithJSONObject: part options: 0 error: nil];
            [mp setNextPartsHeaders: $dict({@"Content-Type", @"application/json"})];
        }
        [mp addData: part];
    }
    self.body = [TDBody bodyWithJSON: mp.allOutput];
    [self setValue: mp.contentType ofHeader: @"Content-Type"];
    [mp release];
}

@end
