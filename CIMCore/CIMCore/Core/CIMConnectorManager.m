//
//  CIMConnectorManager.m
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMConnectorManager.h"
#import "CIM.h"
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
 **/
#define return_from_block  return

// Define the timeouts (in seconds) for retreiving various parts of the XML stream
#define TIMEOUT_CIM_WRITE         -1
#define TIMEOUT_CIM_READ_START    10
#define TIMEOUT_CIM_READ_STREAM   -1

// Define the tags we'll use to differentiate what it is we're currently reading or writing
#define TAG_CIM_READ_START         100
#define TAG_CIM_READ_STREAM        101
#define TAG_CIM_WRITE_START        200
#define TAG_CIM_WRITE_STOP         201
#define TAG_CIM_WRITE_STREAM       202
#define TAG_CIM_WRITE_RECEIPT      203

// Define the timeouts (in seconds) for SRV
#define TIMEOUT_SRV_RESOLUTION 30.0

NSString *const CIMConnectorErrorDomain = @"CIMConnectorErrorDomain";
NSString *const CLIENT_BIND = @"client_bind";
NSString *const CLIENT_HEARTBEAT = @"client_heartbeat";
NSString *const CLIENT_LOGOUT = @"client_logout";
NSString *const CLIENT_DIY = @"client_diy";
NSString *const CLIENT_OFFLINE_MESSAGE = @"client_get_offline_message";

const NSTimeInterval CIMConnectorTimeoutNone = -1;

typedef NS_ENUM(NSInteger, CIMConnectorState) {
    STATE_CIM_DISCONNECTED,
    STATE_CIM_CONNECTING,
    STATE_CIM_OPENING,
    STATE_CIM_NEGOTIATING,
//    STATE_CIM_STARTTLS_1,
//    STATE_CIM_STARTTLS_2,
//    STATE_CIM_POST_NEGOTIATION,
//    STATE_CIM_REGISTERING,
//    STATE_CIM_AUTH,
    STATE_CIM_BINDING,
//    STATE_CIM_START_SESSION,
    STATE_CIM_CONNECTED,
};

enum CIMConnectorFlags
{
    kDidBinded                    = 1 << 1,
    kDidStartNegotiation          = 1 << 2,  // If set, negotiation has started at least once
};

enum CIMStreamConfig
{
    kResetByteCountPerConnection  = 1 << 1,  // If set, byte count should be reset per connection
#if TARGET_OS_IPHONE
    kEnableBackgroundingOnSocket  = 1 << 2,  // If set, the VoIP flag should be set on the socket
#endif
};

@interface CIMConnectorManager ()
{
    dispatch_queue_t willSendMessageQueue;
    dispatch_queue_t willReceiveStanzaQueue;
    
    dispatch_source_t connectTimer;
    
    GCDMulticastDelegate <CIMConnectorDelegate> *multicastDelegate;
    
    CIMConnectorState state;
    
    GCDAsyncSocket *asyncSocket;
    
    
    uint64_t numberOfBytesSent;
    uint64_t numberOfBytesReceived;
    
    CIMParser *parser;
    NSError *parserError;
    NSError *otherError;
    
    Byte flags;
    Byte config;
    
    NSString *hostName;
    UInt16 hostPort;
    
    NSXMLElement *rootElement;
    
    NSTimeInterval keepAliveInterval;
    dispatch_source_t keepAliveTimer;
    NSTimeInterval lastSendReceiveTime;
    NSData *keepAliveData;
    
    NSMutableArray *registeredModules;
    NSMutableDictionary *autoDelegateDict;
    
    NSMutableArray *receipts;
    NSCountedSet *customElementNames;
    
    id userTag;
}

@property (nonatomic, readonly) dispatch_queue_t cimQueue;
@property (nonatomic, readonly) void *cimQueueTag;

@property (atomic, readonly) CIMConnectorState state;

@end

@interface CIMElementReceipt (PrivateAPI)

- (void)signalSuccess;
- (void)signalFailure;

@end

@implementation CIMConnectorManager
@synthesize tag = userTag;
@synthesize userName = _userName;

- (void)dealloc
{
    [asyncSocket setDelegate:nil delegateQueue:NULL];
    [asyncSocket disconnect];
    
    [parser setDelegate:nil delegateQueue:NULL];
    
    if (keepAliveTimer)
    {
        dispatch_source_cancel(keepAliveTimer);
    }
    
    for (CIMElementReceipt *receipt in receipts)
    {
        [receipt signalFailure];
    }
}

- (void)commonInit
{
    cimQueueTag = &cimQueueTag;
    cimQueue = dispatch_queue_create("cim", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(cimQueue, cimQueueTag, cimQueueTag, NULL);
    
    willSendMessageQueue = dispatch_queue_create("cim.willSendMessage", DISPATCH_QUEUE_SERIAL);
    
    multicastDelegate = (GCDMulticastDelegate <CIMConnectorDelegate> *)[[GCDMulticastDelegate alloc] init];
    
    state = STATE_CIM_DISCONNECTED;
    
    flags = 0;
    config = 0;
    
    numberOfBytesSent = 0;
    numberOfBytesReceived = 0;
    
    hostPort = 23456;
    keepAliveInterval = DEFAULT_KEEPALIVE_INTERVAL;
    keepAliveData = [@" " dataUsingEncoding:NSUTF8StringEncoding];
    
    registeredModules = [[NSMutableArray alloc] init];
    autoDelegateDict = [[NSMutableDictionary alloc] init];
    
    receipts = [[NSMutableArray alloc] init];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self commonInit];
        asyncSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:cimQueue];
    }
    return self;
}

#pragma mark - Properties
@synthesize cimQueue;
@synthesize cimQueueTag;

- (CIMConnectorState)state
{
    __block CIMConnectorState result = STATE_CIM_DISCONNECTED;
    
    dispatch_block_t block = ^{
        result = state;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (NSString *)userName
{
    if (dispatch_get_specific(cimQueueTag))
    {
        return _userName;
    }
    else
    {
        __block NSString *result;
        
        dispatch_sync(cimQueue, ^{
            result = _userName;
        });
        
        return result;
    }
}

-(void)setUserName:(NSString *)userName
{
    if (dispatch_get_specific(cimQueueTag))
    {
        if (_userName != userName)
        {
            _userName = [userName copy];
        }
    }
    else
    {
        NSString *newUserNameCopy = [userName copy];
        
        dispatch_async(cimQueue, ^{
            _userName = newUserNameCopy;
        });
        
    }
}

- (NSString *)hostName
{
    if (dispatch_get_specific(cimQueueTag))
    {
        return hostName;
    }
    else
    {
        __block NSString *result;
        
        dispatch_sync(cimQueue, ^{
            result = hostName;
        });
        
        return result;
    }
}

- (void)setHostName:(NSString *)newHostName
{
    if (dispatch_get_specific(cimQueueTag))
    {
        if (hostName != newHostName)
        {
            hostName = [newHostName copy];
        }
    }
    else
    {
        NSString *newHostNameCopy = [newHostName copy];
        
        dispatch_async(cimQueue, ^{
            hostName = newHostNameCopy;
        });
        
    }
}

- (UInt16)hostPort
{
    if (dispatch_get_specific(cimQueueTag))
    {
        return hostPort;
    }
    else
    {
        __block UInt16 result;
        
        dispatch_sync(cimQueue, ^{
            result = hostPort;
        });
        
        return result;
    }
}

- (void)setHostPort:(UInt16)newHostPort
{
    dispatch_block_t block = ^{
        hostPort = newHostPort;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (NSTimeInterval)keepAliveInterval
{
    __block NSTimeInterval result = 0.0;
    
    dispatch_block_t block = ^{
        result = keepAliveInterval;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (void)setKeepAliveInterval:(NSTimeInterval)interval
{
    dispatch_block_t block = ^{
        
        if (keepAliveInterval != interval)
        {
            if (interval <= 0.0)
                keepAliveInterval = interval;
            else
                keepAliveInterval = MAX(interval, MIN_KEEPALIVE_INTERVAL);
            
            [self setupKeepAliveTimer];
        }
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (char)keepAliveWhitespaceCharacter
{
    __block char keepAliveChar = ' ';
    
    dispatch_block_t block = ^{
        
        NSString *keepAliveString = [[NSString alloc] initWithData:keepAliveData encoding:NSUTF8StringEncoding];
        if ([keepAliveString length] > 0)
        {
            keepAliveChar = (char)[keepAliveString characterAtIndex:0];
        }
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return keepAliveChar;
}

- (void)setKeepAliveWhitespaceCharacter:(char)keepAliveChar
{
    dispatch_block_t block = ^{
        
        if (keepAliveChar == ' ' || keepAliveChar == '\n' || keepAliveChar == '\t')
        {
            keepAliveData = [[NSString stringWithFormat:@"%c", keepAliveChar] dataUsingEncoding:NSUTF8StringEncoding];
        }
        else
        {
//            cimLogWarn(@"Invalid whitespace character! Must be: space, newline, or tab");
        }
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (uint64_t)numberOfBytesSent
{
    __block uint64_t result = 0;
    
    dispatch_block_t block = ^{
        result = numberOfBytesSent;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (uint64_t)numberOfBytesReceived
{
    __block uint64_t result = 0;
    
    dispatch_block_t block = ^{
        result = numberOfBytesReceived;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (void)getNumberOfBytesSent:(uint64_t *)bytesSentPtr numberOfBytesReceived:(uint64_t *)bytesReceivedPtr
{
    __block uint64_t bytesSent = 0;
    __block uint64_t bytesReceived = 0;
    
    dispatch_block_t block = ^{
        bytesSent = numberOfBytesSent;
        bytesReceived = numberOfBytesReceived;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    if (bytesSentPtr) *bytesSentPtr = bytesSent;
    if (bytesReceivedPtr) *bytesReceivedPtr = bytesReceived;
}

- (BOOL)resetByteCountPerConnection
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (config & kResetByteCountPerConnection) ? YES : NO;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (void)setResetByteCountPerConnection:(BOOL)flag
{
    dispatch_block_t block = ^{
        if (flag)
            config |= kResetByteCountPerConnection;
        else
            config &= ~kResetByteCountPerConnection;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (BOOL)enableBackgroundingOnSocket
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (config & kEnableBackgroundingOnSocket) ? YES : NO;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

- (void)setEnableBackgroundingOnSocket:(BOOL)flag
{
    dispatch_block_t block = ^{
        if (flag)
            config |= kEnableBackgroundingOnSocket;
        else
            config &= ~kEnableBackgroundingOnSocket;
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

#pragma mark - Configuration
- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue
{
    // Asynchronous operation (if outside cimQueue)
    
    dispatch_block_t block = ^{
        [multicastDelegate addDelegate:delegate delegateQueue:delegateQueue];
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue
{
    // Synchronous operation
    
    dispatch_block_t block = ^{
        [multicastDelegate removeDelegate:delegate delegateQueue:delegateQueue];
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (void)removeDelegate:(id)delegate
{
    // Synchronous operation
    
    dispatch_block_t block = ^{
        [multicastDelegate removeDelegate:delegate];
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (BOOL)didStartNegotiation
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    return (flags & kDidStartNegotiation) ? YES : NO;
}

- (void)setDidStartNegotiation:(BOOL)flag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (flag)
        flags |= kDidStartNegotiation;
    else
        flags &= ~kDidStartNegotiation;
}

- (BOOL)didBinding
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    return (flags & kDidBinded) ? YES : NO;
}

- (void)setdidBinding:(BOOL)flag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (flag)
        flags |= kDidBinded;
    else
        flags &= ~kDidBinded;
}

#pragma mark - Connection State
/**
 * Returns YES if the connection is closed, and thus no stream is open.
 * If the stream is neither disconnected, nor connected, then a connection is currently being established.
 **/
- (BOOL)isDisconnected
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (state == STATE_CIM_DISCONNECTED);
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

/**
 * Returns YES is the connection is currently connecting
 **/
- (BOOL)isConnecting
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        result = (state == STATE_CIM_CONNECTING);
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}
/**
 * Returns YES if the connection is open, and the stream has been properly established.
 * If the stream is neither disconnected, nor connected, then a connection is currently being established.
 **/
- (BOOL)isConnected
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (state == STATE_CIM_CONNECTED);
    };
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    return result;
}

#pragma mark - Connect Timeout
/**
 * Start Connect Timeout
 **/
- (void)startConnectTimeout:(NSTimeInterval)timeout
{
    if (timeout >= 0.0 && !connectTimer)
    {
        connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cimQueue);
        
        dispatch_source_set_event_handler(connectTimer, ^{ @autoreleasepool {
            
            [self doConnectTimeout];
        }});
        
        dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeout * NSEC_PER_SEC));
        dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
        
        dispatch_resume(connectTimer);
    }
}

/**
 * End Connect Timeout
 **/
- (void)endConnectTimeout
{
    if (connectTimer)
    {
        dispatch_source_cancel(connectTimer);
        connectTimer = NULL;
    }
}

/**
 * Connect has timed out, so inform the delegates and close the connection
 **/
- (void)doConnectTimeout
{
    [self endConnectTimeout];
    
    if (state != STATE_CIM_DISCONNECTED)
    {
        [multicastDelegate cimConnectorConnectDidTimeout:self];
        
        [asyncSocket disconnect];
        
        // Everthing will be handled in socketDidDisconnect:withError:
    }
}

#pragma mark - C2S Connection
- (BOOL)connectToHost:(NSString *)host onPort:(UInt16)port withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    BOOL result = [asyncSocket connectToHost:host onPort:port error:errPtr];
    
    if (result && [self resetByteCountPerConnection])
    {
        numberOfBytesSent = 0;
        numberOfBytesReceived = 0;
    }
    
    if(result)
    {
        [self startConnectTimeout:timeout];
    }
    
    return result;
}

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
    __block BOOL result = NO;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (state != STATE_CIM_DISCONNECTED)
        {
            NSString *errMsg = @"Attempting to connect while already connected or connecting.";
            NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
            
            err = [NSError errorWithDomain:CIMConnectorErrorDomain code:-1000 userInfo:info];
            
            result = NO;
            return_from_block;
        }
        // Notify delegates
        [multicastDelegate cimConnectorWillConnect:self];
        
        {
            // Open TCP connection to the configured hostName.
            
            state = STATE_CIM_CONNECTING;
            
            NSError *connectErr = nil;
            result = [self connectToHost:hostName onPort:hostPort withTimeout:CIMConnectorTimeoutNone error:&connectErr];
            
            if (!result)
            {
                err = connectErr;
                state = STATE_CIM_DISCONNECTED;
            }
        }
        
        if(result)
        {
            [self startConnectTimeout:timeout];
        }
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

#pragma mark - Disconnect
- (void)disconnect
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (state != STATE_CIM_DISCONNECTED)
        {
            [multicastDelegate cimConnectorWasToldToDisconnect:self];
            [asyncSocket disconnect];
            
            // Everthing will be handled in socketDidDisconnect:withError:
        }
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (void)disconnectAfterSending
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (state != STATE_CIM_DISCONNECTED)
        {
            [multicastDelegate cimConnectorWasToldToDisconnect:self];
            
            NSString *termStr = @" ";
            NSData *termData = [termStr dataUsingEncoding:NSUTF8StringEncoding];
            numberOfBytesSent += [termData length];
            [asyncSocket writeData:termData withTimeout:TIMEOUT_CIM_WRITE tag:TAG_CIM_WRITE_STOP];
            [asyncSocket disconnectAfterWriting];
            
            // Everthing will be handled in socketDidDisconnect:withError:
        }
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (NSXMLElement *)rootElement
{
    if (dispatch_get_specific(cimQueueTag))
    {
        return rootElement;
    }
    else
    {
        __block NSXMLElement *result = nil;
        
        dispatch_sync(cimQueue, ^{
            result = [rootElement copy];
        });
        
        return result;
    }
}

- (void)sendMessage:(CIMMessage *)message withTag:(long)tag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_CIM_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to send a message.
    // Notify delegates to allow them to optionally alter/filter the outgoing message.
    
    SEL selector = @selector(cimConnector:willSendMessage:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        [self continueSendMessage:message withTag:tag];
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_async(willSendMessageQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify outgoing element
            
            __block CIMMessage *modifiedMessage = message;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedMessage && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
#if DEBUG
                {
                    char methodReturnType[32];
                    
                    Method method = class_getInstanceMethod([del class], selector);
                    method_getReturnType(method, methodReturnType, sizeof(methodReturnType));
                    
                    if (strcmp(methodReturnType, @encode(CIMMessage*)) != 0)
                    {
                        NSAssert(NO, @"Method cimConnector:willSendMessage: is no longer void. "
                                 @"Culprit = %@", NSStringFromClass([del class]));
                    }
                }
#endif
                
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedMessage = [del cimConnector:self willSendMessage:modifiedMessage];
                    
                }});
            }
            
            if (modifiedMessage)
            {
                dispatch_async(cimQueue, ^{ @autoreleasepool {
                    
                    if (state == STATE_CIM_CONNECTED) {
                        [self continueSendMessage:modifiedMessage withTag:tag];
                    }
                    else {
                        [self failToSendMessage:modifiedMessage];
                    }
                }});
            }
        }});
    }
}

- (void)continueSendMessage:(CIMMessage *)message withTag:(long)tag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_CIM_CONNECTED, @"Invoked with incorrect state");
    NSString *outgoingStr = [message compactXMLString];
    NSData *outgoingData = [outgoingStr dataUsingEncoding:NSUTF8StringEncoding];
    
    numberOfBytesSent += [outgoingData length];
    
    [asyncSocket writeData:outgoingData
               withTimeout:TIMEOUT_CIM_WRITE
                       tag:tag];
    
    [multicastDelegate cimConnector:self didSendMessage:message];
}

- (void)failToSendMessage:(CIMMessage *)message
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    NSError *error = [NSError errorWithDomain:CIMConnectorErrorDomain
                                         code:-1000
                                     userInfo:nil];
    
    [multicastDelegate cimConnector:self didFailToSendMessage:message error:error];
}

- (void)continueSendElement:(NSXMLElement *)element withTag:(long)tag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_CIM_CONNECTED, @"Invoked with incorrect state");
    NSString *outgoingStr = [element compactXMLString];
    NSData *outgoingData = [outgoingStr dataUsingEncoding:NSUTF8StringEncoding];
    
    numberOfBytesSent += [outgoingData length];
    
    [asyncSocket writeData:outgoingData
               withTimeout:TIMEOUT_CIM_WRITE
                       tag:tag];
    
    if ([customElementNames countForObject:[element name]])
    {
        [multicastDelegate cimConnector:self didSendCustomElement:element];
    }
}
/**
 * Private method.
 * Presencts a common method for the various public sendElement methods.
 **/
- (void)sendElement:(NSXMLElement *)element withTag:(long)tag
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if ([element isKindOfClass:[CIMMessage class]])
    {
        [self sendMessage:(CIMMessage *)element withTag:tag];
    }
    else
    {
        NSString *elementName = [element name];
        
        if ([elementName isEqualToString:@"message"])
        {
#warning CIMMessage
//            [self sendMessage:[CIMMessage messageFromElement:element] withTag:tag];
        }
        else
        {
            [self continueSendElement:element withTag:tag];
        }
    }
}

- (void)sendElement:(NSXMLElement *)element
{
    if (element == nil) return;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (state == STATE_CIM_CONNECTED)
        {
            [self sendElement:element withTag:TAG_CIM_WRITE_STREAM];
        }
        else
        {
            [self failToSendElement:element];
        }
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (void)sendElement:(NSXMLElement *)element andGetReceipt:(CIMElementReceipt **)receiptPtr
{
    if (element == nil) return;
    
    if (receiptPtr == nil)
    {
        [self sendElement:element];
    }
    else
    {
        __block CIMElementReceipt *receipt = nil;
        
        dispatch_block_t block = ^{ @autoreleasepool {
            
            if (state == STATE_CIM_CONNECTED)
            {
                receipt = [[CIMElementReceipt alloc] init];
                [receipts addObject:receipt];
                
                [self sendElement:element withTag:TAG_CIM_WRITE_RECEIPT];
            }
            else
            {
                [self failToSendElement:element];
            }
        }};
        
        if (dispatch_get_specific(cimQueueTag))
            block();
        else
            dispatch_sync(cimQueue, block);
        
        *receiptPtr = receipt;
    }
}

- (void)failToSendElement:(NSXMLElement *)element
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if ([element isKindOfClass:[CIMMessage class]])
    {
        [self failToSendMessage:(CIMMessage *)element];
    }
//    else if ([element isKindOfClass:[XMPPPresence class]])
//    {
//        [self failToSendPresence:(XMPPPresence *)element];
//    }
//    else
//    {
//        NSString *elementName = [element name];
//        
//        if ([elementName isEqualToString:@"iq"])
//        {
//            [self failToSendIQ:[XMPPIQ iqFromElement:element]];
//        }
//        else if ([elementName isEqualToString:@"message"])
//        {
//            [self failToSendMessage:[XMPPMessage messageFromElement:element]];
//        }
//        else if ([elementName isEqualToString:@"presence"])
//        {
//            [self failToSendPresence:[XMPPPresence presenceFromElement:element]];
//        }
//    }
}

- (void)sendBindElement:(NSXMLElement *)element
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (state == STATE_CIM_BINDING)
        {
            NSString *outgoingStr = [element compactXMLString];
            NSData *outgoingData = [outgoingStr dataUsingEncoding:NSUTF8StringEncoding];
            
            numberOfBytesSent += [outgoingData length];
            
            [asyncSocket writeData:outgoingData
                       withTimeout:TIMEOUT_CIM_WRITE
                               tag:TAG_CIM_WRITE_STREAM];
        }
        else
        {
//            (@"Unable to send element while not in STATE_CIM_BINDING: %@", [element compactXMLString]);
        }
    }};
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (void)receiveReplyBody:(CIMReplyBody*)replyBody
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
//    NSAssert(state == STATE_CIM_CONNECTED, @"Invoked with incorrect state");
    
    SEL selector = @selector(cimConnector:willReceiveReplyBody:);
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        [self continueReceiveReplyBody:replyBody];
    }
}

- (void)continueReceiveReplyBody:(CIMReplyBody *)replyBody
{
    [multicastDelegate cimConnector:self didReceiveReplyBody:replyBody];
}

- (void)receiveMessage:(CIMMessage *)message
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_CIM_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to receive a message.
    // Notify delegates to allow them to optionally alter/filter the incoming message.
    
    SEL selector = @selector(cimConnector:willReceiveMessage:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        [self continueReceiveMessage:message];
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        if (willReceiveStanzaQueue == NULL)
            willReceiveStanzaQueue = dispatch_queue_create("CIM.willReceiveStanza", DISPATCH_QUEUE_SERIAL);
        
        dispatch_async(willReceiveStanzaQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify incoming element
            
            __block CIMMessage *modifiedMessage = message;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedMessage && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedMessage = [del cimConnector:self willReceiveMessage:modifiedMessage];
                    
                }});
            }
            
            dispatch_async(cimQueue, ^{ @autoreleasepool {
                
                if (state == STATE_CIM_CONNECTED)
                {
                    if (modifiedMessage)
                        [self continueReceiveMessage:modifiedMessage];
                    else
                        [multicastDelegate cimConnectorDidFilterStanza:self];
                }
            }});
        }});
    }
}

- (void)continueReceiveMessage:(CIMMessage *)message
{
    [multicastDelegate cimConnector:self didReceiveMessage:message];
}

/**
* This method allows you to inject an element into the stream as if it was received on the socket.
* This is an advanced technique, but makes for some interesting possibilities.
**/
//- (void)injectElement:(NSXMLElement *)element
//{
//    if (element == nil) return;
//    
//    dispatch_block_t block = ^{ @autoreleasepool {
//        
//        if (state != STATE_CIM_CONNECTED)
//        {
//            return_from_block;
//        }
//        
//        if ([element isKindOfClass:[CIMMessage class]])
//        {
//            [self receiveMessage:(CIMMessage *)element];
//        }
//        else
//        {
//            NSString *elementName = [element name];
//
//            else if ([elementName isEqualToString:@"message"])
//            {
//                [self receiveMessage:[XMPPMessage messageFromElement:element]];
//            }
//            else if ([customElementNames countForObject:elementName])
//            {
//                [multicastDelegate xmppStream:self didReceiveCustomElement:element];
//            }
//            else
//            {
//                [multicastDelegate xmppStream:self didReceiveError:element];
//            }
//        }
//    }};
//    
//    if (dispatch_get_specific(cimQueueTag))
//        block();
//    else
//        dispatch_async(cimQueue, block);
//}

#pragma mark Stream Negotiation
/**
 * This method is called to start the initial negotiation process.
 **/
- (void)startNegotiation
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    NSAssert(![self didStartNegotiation], @"Invoked after initial negotiation has started");
    
    // Initialize the XML stream
    [self sendOpeningNegotiation];
    
    // Inform delegate that the TCP connection is open, and the stream handshake has begun
    [multicastDelegate cimConnectorDidStartNegotiation:self];
    
    // And start reading in the server's XML stream
    [asyncSocket readDataWithTimeout:TIMEOUT_CIM_READ_START tag:TAG_CIM_READ_START];
}

- (void)sendOpeningNegotiation
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (![self didStartNegotiation])
    {
        // TCP connection was just opened - We need to include the opening XML stanza
        NSString *s1 = [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><sent><key>client_bind</key><timestamp>%.0f</timestamp><data><device>iPhone</device><account>xmpptest</account><channel>iOS</channel><deviceId>904d921235ab3e4981a3055015e4a3sdfafd</deviceId></data></sent>\b",[[NSDate date] timeIntervalSince1970]];
        
        NSMutableData *outgoingData = [NSMutableData dataWithData:[s1 dataUsingEncoding:NSUTF8StringEncoding]];
        
        numberOfBytesSent += [outgoingData length];
        
        [asyncSocket writeData:outgoingData
                   withTimeout:TIMEOUT_CIM_WRITE
                           tag:TAG_CIM_WRITE_START];
        
        [self setDidStartNegotiation:YES];
    }
    
    if (parser == nil)
    {
        // Need to create the parser.
        parser = [[CIMParser alloc] initWithDelegate:self delegateQueue:cimQueue];
    }
    else
    {
        // We're restarting our negotiation, so we need to reset the parser.
        parser = [[CIMParser alloc] initWithDelegate:self delegateQueue:cimQueue];
    }
    
//    NSString *xmlns = @"jabber:client";
//    NSString *xmlns_stream = @"http://etherx.jabber.org/streams";
//    
//    NSString *s2;
//    
//    NSData *outgoingData = [s2 dataUsingEncoding:NSUTF8StringEncoding];
//
//    numberOfBytesSent += [outgoingData length];
//    
//    [asyncSocket writeData:outgoingData
//               withTimeout:TIMEOUT_CIM_WRITE
//                       tag:TAG_CIM_WRITE_START];
    
    // Update status
    state = STATE_CIM_OPENING;
}

/**
 * This method is called anytime we receive the server's stream features.
 * This method looks at the stream features, and handles any requirements so communication can continue.
 **/
- (void)handleStreamFeatures
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (![self didBinding])
    {
        // Start the binding process
        [self startBinding];
        
        // We're already listening for the response...
        return;
    }

    // It looks like all has gone well, and the connection should be ready to use now
    state = STATE_CIM_CONNECTED;
    
    if ([self didBinding])
    {
        [self setupKeepAliveTimer];
        
        // Notify delegates
        [multicastDelegate cimConnectorDidConnect:self];
    }
}

- (void)startBinding
{
    state = STATE_CIM_BINDING;
    
//    SEL selector = @selector(cimConnectorWillBind:);
//    
//    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
//    {
//        [self startStandardBinding];
//    }
//    else
//    {
//        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
//        
//        dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
//        dispatch_async(concurrentQueue, ^{ @autoreleasepool {
//            
//            __block id <XMPPCustomBinding> delegateCustomBinding = nil;
//            
//            id delegate;
//            dispatch_queue_t dq;
//            
//            while ([delegateEnumerator getNextDelegate:&delegate delegateQueue:&dq forSelector:selector])
//            {
//                dispatch_sync(dq, ^{ @autoreleasepool {
//                    
//                    delegateCustomBinding = [delegate xmppStreamWillBind:self];
//                }});
//                
//                if (delegateCustomBinding) {
//                    break;
//                }
//            }
//            
//            dispatch_async(cimQueue, ^{ @autoreleasepool {
//                
//                if (delegateCustomBinding)
//                    [self startCustomBinding:delegateCustomBinding];
//                else
//                    [self startStandardBinding];
//            }});
//        }});
//    }
}

#pragma mark - AsyncSocket Delegate
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    // This method is invoked on the cimQueue.
    //
    // The TCP connection is now established.
    
    [self endConnectTimeout];
    
#if TARGET_OS_IPHONE
    {
        if (self.enableBackgroundingOnSocket)
        {
            __block BOOL result;
            
            [asyncSocket performBlock:^{
                result = [asyncSocket enableBackgroundingOnSocket];
            }];
            
//            if (result)
//                (@"%@: Enabled backgrounding on socket", THIS_FILE);
//            else
//                (@"%@: Error enabling backgrounding on socket!", THIS_FILE);
        }
    }
#endif
    
    [multicastDelegate cimConnector:self socketDidConnect:sock];
    
    [self startNegotiation];
}

- (void)socket:(GCDAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
//    SEL selector = @selector(cimConnector:didReceiveTrust:completionHandler:);
//    
//    if ([multicastDelegate hasDelegateThatRespondsToSelector:selector])
//    {
//        [multicastDelegate cimConnector:self didReceiveTrust:trust completionHandler:completionHandler];
//    }
//    else
//    {
//        (@"%@: Stream secured with (GCDAsyncSocketManuallyEvaluateTrust == YES),"
//                    @" but there are no delegates that implement cimConnector:didReceiveTrust:completionHandler:."
//                    @" This is likely a mistake.", THIS_FILE);
//        
//        // The delegate method should likely have code similar to this,
//        // but will presumably perform some extra security code stuff.
//        // For example, allowing a specific self-signed certificate that is known to the app.
//        
//        dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
//        dispatch_async(bgQueue, ^{
//            
//            SecTrustResultType result = kSecTrustResultDeny;
//            OSStatus status = SecTrustEvaluate(trust, &result);
//            
//            if (status == noErr && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified)) {
//                completionHandler(YES);
//            }
//            else {
//                completionHandler(NO);
//            }
//        });
//    }
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    // This method is invoked on the cimQueue.
    
//    [multicastDelegate cimConnectorDidSecure:self];
}

/**
 * Called when a socket has completed reading the requested data. Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    // This method is invoked on the cimQueue.
    
    lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
    numberOfBytesReceived += [data length];
    
//    (@"RECV: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    
    // Asynchronously parse the xml data
    [parser parseData:data];
}

/**
 * Called after data with the given tag has been successfully sent.
 **/
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    // This method is invoked on the cimQueue.
    
    lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
    
    if (tag == TAG_CIM_WRITE_RECEIPT)
    {
        if ([receipts count] == 0)
        {
//            (@"%@: Found TAG_CIM_WRITE_RECEIPT with no pending receipts!", THIS_FILE);
            return;
        }
        
        CIMElementReceipt *receipt = [receipts objectAtIndex:0];
        [receipt signalSuccess];
        [receipts removeObjectAtIndex:0];
    }
    else if (tag == TAG_CIM_WRITE_STOP)
    {
//        [multicastDelegate cimConnectorDidSendClosingStreamStanza:self];
    }
}

/**
 * Called when a socket disconnects with or without error.
 **/
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    // This method is invoked on the cimQueue.
    
    [self endConnectTimeout];
    
    {
        // Update state
        state = STATE_CIM_DISCONNECTED;
        
        // Release the parser (to free underlying resources)
        [parser setDelegate:nil delegateQueue:NULL];
        parser = nil;
        
        rootElement = nil;
        
        // Stop the keep alive timer
        if (keepAliveTimer)
        {
            dispatch_source_cancel(keepAliveTimer);
            keepAliveTimer = NULL;
        }
        
        // Clear any pending receipts
        for (CIMElementReceipt *receipt in receipts)
        {
            [receipt signalFailure];
        }
        [receipts removeAllObjects];
        
        // Clear flags
        flags = 0;
        
        // Notify delegate
        
        if (parserError || otherError)
        {
            NSError *error = parserError ? : otherError;
            
            [multicastDelegate cimConnectorDidDisconnect:self withError:error];
            
            parserError = nil;
            otherError = nil;
        }
        else
        {
            [multicastDelegate cimConnectorDidDisconnect:self withError:err];
        }
    }
}

#pragma mark - CIMParser Delegate
- (void)cimParser:(CIMParser *)sender didReadRoot:(NSXMLElement *)root
{
    // This method is invoked on the cimQueue.
    
    if (sender != parser) return;
    
    rootElement = root;
    state = STATE_CIM_NEGOTIATING;
}

- (void)cimParser:(CIMParser *)sender didReadElement:(NSXMLElement *)element
{
    if (sender != parser) return;
    NSString *elementName = [element name];
    if (state == STATE_CIM_NEGOTIATING)
    {
        [self handleStreamFeatures];
    }
//    if ([elementName isEqualToString:@"stream:error"] || [elementName isEqualToString:@"error"])
//    {
//        [multicastDelegate cimConnector:self didReceiveError:element];
//        
//        return;
//    }
//    if ([elementName isEqualToString:@"message"])
//    {
//        [self receiveMessage:[CIMMessage messageFromElement:element]];
//    }else
//    {
//        [multicastDelegate cimConnector:self didReceiveError:element];
//    }
}

- (void)cimParserDidEnd:(CIMParser *)sender
{
    if (sender != parser) return;
    rootElement = sender.rootElement;
    if ([[rootElement name] isEqualToString:@"reply"]) {
        [self receiveReplyBody:(CIMReplyBody*)rootElement];
        if ([[rootElement attributeStringValueForName:@"key"] isEqualToString:CLIENT_BIND]) {
            if ([[rootElement attributeStringValueForName:@"code"] isEqualToString:@"200"]) {
                
            }
        }
    }else if ([[rootElement name] isEqualToString:@"message"])
    {
        [self receiveMessage:(CIMMessage*)rootElement];
    }else
    {
        
    }
}

- (void)cimParser:(CIMParser *)sender didFail:(NSError *)error
{
    // This method is invoked on the cimQueue.
    
    if (sender != parser) return;
    
    parserError = error;
//    [asyncSocket disconnect];
}

#pragma mark - Keep Alive
- (void)setupKeepAliveTimer
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (keepAliveTimer)
    {
        dispatch_source_cancel(keepAliveTimer);
        keepAliveTimer = NULL;
    }
    
    if (state == STATE_CIM_CONNECTED)
    {
        if (keepAliveInterval > 0)
        {
            keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cimQueue);
            
            dispatch_source_set_event_handler(keepAliveTimer, ^{ @autoreleasepool {
                
                [self keepAlive];
            }});
            
            // Everytime we send or receive data, we update our lastSendReceiveTime.
            // We set our timer to fire several times per keepAliveInterval.
            // This allows us to maintain a single timer,
            // and an acceptable timer resolution (assuming larger keepAliveIntervals).
            
            uint64_t interval = ((keepAliveInterval / 4.0) * NSEC_PER_SEC);
            
            dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, interval);
            
            dispatch_source_set_timer(keepAliveTimer, tt, interval, 1.0);
            dispatch_resume(keepAliveTimer);
        }
    }
}

- (void)keepAlive
{
    NSAssert(dispatch_get_specific(cimQueueTag), @"Invoked on incorrect queue");
    
    if (state == STATE_CIM_CONNECTED)
    {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = (now - lastSendReceiveTime);
        
        if (elapsed < 0 || elapsed >= keepAliveInterval)
        {
            numberOfBytesSent += [keepAliveData length];
            
            [asyncSocket writeData:keepAliveData
                       withTimeout:TIMEOUT_CIM_WRITE
                               tag:TAG_CIM_WRITE_STREAM];
            
            // Force update the lastSendReceiveTime here just to be safe.
            // 
            // In case the TCP socket comes to a crawl with a giant element in the queue,
            // which would prevent the socket:didWriteDataWithTag: method from being called for some time.
            
            lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
        }
    }
}

#pragma mark Module - Plug-In System
- (void)registerModule:(CIMModule *)module
{
    if (module == nil) return;
    
    // Asynchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // Register module
        
        [registeredModules addObject:module];
        
        // Add auto delegates (if there are any)
        
        NSString *className = NSStringFromClass([module class]);
        GCDMulticastDelegate *autoDelegates = [autoDelegateDict objectForKey:className];
        
        GCDMulticastDelegateEnumerator *autoDelegatesEnumerator = [autoDelegates delegateEnumerator];
        id delegate;
        dispatch_queue_t delegateQueue;
        
        while ([autoDelegatesEnumerator getNextDelegate:&delegate delegateQueue:&delegateQueue])
        {
            [module addDelegate:delegate delegateQueue:delegateQueue];
        }
        
        // Notify our own delegate(s)
        
        [multicastDelegate cimConnector:self didRegisterModule:module];
        
    }};
    
    // Asynchronous operation
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (void)unregisterModule:(CIMModule *)module
{
    if (module == nil) return;
    
    // Synchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // Notify our own delegate(s)
        
        [multicastDelegate cimConnector:self willUnregisterModule:module];
        
        // Remove auto delegates (if there are any)
        
        NSString *className = NSStringFromClass([module class]);
        GCDMulticastDelegate *autoDelegates = [autoDelegateDict objectForKey:className];
        
        GCDMulticastDelegateEnumerator *autoDelegatesEnumerator = [autoDelegates delegateEnumerator];
        id delegate;
        dispatch_queue_t delegateQueue;
        
        while ([autoDelegatesEnumerator getNextDelegate:&delegate delegateQueue:&delegateQueue])
        {
            // The module itself has dispatch_sync'd in order to invoke its deactivate method,
            // which has in turn invoked this method. If we call back into the module,
            // and have it dispatch_sync again, we're going to get a deadlock.
            // So we must remove the delegate(s) asynchronously.
            
            [module removeDelegate:delegate delegateQueue:delegateQueue synchronously:NO];
        }
        
        // Unregister modules
        
        [registeredModules removeObject:module];
        
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (void)autoAddDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue toModulesOfClass:(Class)aClass
{
    if (delegate == nil) return;
    if (aClass == nil) return;
    
    // Asynchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        NSString *className = NSStringFromClass(aClass);
        
        // Add the delegate to all currently registered modules of the given class.
        
        for (CIMModule *module in registeredModules)
        {
            if ([module isKindOfClass:aClass])
            {
                [module addDelegate:delegate delegateQueue:delegateQueue];
            }
        }
        
        // Add the delegate to list of auto delegates for the given class.
        // It will be added as a delegate to future registered modules of the given class.
        
        id delegates = [autoDelegateDict objectForKey:className];
        if (delegates == nil)
        {
            delegates = [[GCDMulticastDelegate alloc] init];
            
            [autoDelegateDict setObject:delegates forKey:className];
        }
        
        [delegates addDelegate:delegate delegateQueue:delegateQueue];
        
    }};
    
    // Asynchronous operation
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_async(cimQueue, block);
}

- (void)removeAutoDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue fromModulesOfClass:(Class)aClass
{
    if (delegate == nil) return;
    // delegateQueue may be NULL
    // aClass may be NULL
    
    // Synchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (aClass == NULL)
        {
            // Remove the delegate from all currently registered modules of ANY class.
            
            for (CIMModule *module in registeredModules)
            {
                [module removeDelegate:delegate delegateQueue:delegateQueue];
            }
            
            // Remove the delegate from list of auto delegates for all classes,
            // so that it will not be auto added as a delegate to future registered modules.
            
            for (GCDMulticastDelegate *delegates in [autoDelegateDict objectEnumerator])
            {
                [delegates removeDelegate:delegate delegateQueue:delegateQueue];
            }
        }
        else
        {
            NSString *className = NSStringFromClass(aClass);
            
            // Remove the delegate from all currently registered modules of the given class.
            
            for (CIMModule *module in registeredModules)
            {
                if ([module isKindOfClass:aClass])
                {
                    [module removeDelegate:delegate delegateQueue:delegateQueue];
                }
            }
            
            // Remove the delegate from list of auto delegates for the given class,
            // so that it will not be added as a delegate to future registered modules of the given class.
            
            GCDMulticastDelegate *delegates = [autoDelegateDict objectForKey:className];
            [delegates removeDelegate:delegate delegateQueue:delegateQueue];
            
            if ([delegates count] == 0)
            {
                [autoDelegateDict removeObjectForKey:className];
            }
        }
        
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (void)enumerateModulesWithBlock:(void (^)(CIMModule *module, NSUInteger idx, BOOL *stop))enumBlock
{
    if (enumBlock == NULL) return;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        NSUInteger i = 0;
        BOOL stop = NO;
        
        for (CIMModule *module in registeredModules)
        {
            enumBlock(module, i, &stop);
            
            if (stop)
                break;
            else
                i++;
        }
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(cimQueueTag))
        block();
    else
        dispatch_sync(cimQueue, block);
}

- (void)enumerateModulesOfClass:(Class)aClass withBlock:(void (^)(CIMModule *module, NSUInteger idx, BOOL *stop))block
{
    [self enumerateModulesWithBlock:^(CIMModule *module, NSUInteger idx, BOOL *stop)
     {
         if([module isKindOfClass:aClass])
         {
             block(module,idx,stop);
         }
     }];
}

#pragma mark - Utilities
+ (NSString *)generateUUID
{
    NSString *result = nil;
    
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    if (uuid)
    {
        result = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
        CFRelease(uuid);
    }
    
    return result;
}

- (NSString *)generateUUID
{
    return [[self class] generateUUID];
}

@end

@implementation CIMElementReceipt

static const uint32_t receipt_unknown = 0 << 0;
static const uint32_t receipt_failure = 1 << 0;
static const uint32_t receipt_success = 1 << 1;


- (id)init
{
    if ((self = [super init]))
    {
        atomicFlags = receipt_unknown;
        semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)signalSuccess
{
    uint32_t mask = receipt_success;
    OSAtomicOr32Barrier(mask, &atomicFlags);
    
    dispatch_semaphore_signal(semaphore);
}

- (void)signalFailure
{
    uint32_t mask = receipt_failure;
    OSAtomicOr32Barrier(mask, &atomicFlags);
    
    dispatch_semaphore_signal(semaphore);
}

- (BOOL)wait:(NSTimeInterval)timeout_seconds
{
    uint32_t mask = 0;
    uint32_t flags = OSAtomicOr32Barrier(mask, &atomicFlags);
    
    if (flags != receipt_unknown) return (flags == receipt_success);
    
    dispatch_time_t timeout_nanos;
    
    if (isless(timeout_seconds, 0.0))
        timeout_nanos = DISPATCH_TIME_FOREVER;
    else
        timeout_nanos = dispatch_time(DISPATCH_TIME_NOW, (timeout_seconds * NSEC_PER_SEC));
    
    // dispatch_semaphore_wait
    //
    // Decrement the counting semaphore. If the resulting value is less than zero,
    // this function waits in FIFO order for a signal to occur before returning.
    //
    // Returns zero on success, or non-zero if the timeout occurred.
    //
    // Note: If the timeout occurs, the semaphore value is incremented (without signaling).
    
    long result = dispatch_semaphore_wait(semaphore, timeout_nanos);
    
    if (result == 0)
    {
        flags = OSAtomicOr32Barrier(mask, &atomicFlags);
        
        return (flags == receipt_success);
    }
    else
    {
        // Timed out waiting...
        return NO;
    }
}

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

@end
