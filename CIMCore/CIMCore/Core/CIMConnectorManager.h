//
//  CIMConnectorManager.h
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GCDAsyncSocket.h"
#import "GCDMulticastDelegate.h"
#import "DDXML.h"

@class CIMModule;
@class CIMParser;
@class CIMMessage;
@class CIMReplyBody;
@class CIMSendBody;
@class CIMElementReceipt;
@protocol CIMConnectorDelegate;

#define MIN_KEEPALIVE_INTERVAL      20.0 // 20 Seconds
#define DEFAULT_KEEPALIVE_INTERVAL 120.0 //  2 Minutes

extern const NSTimeInterval CIMConnectorTimeoutNone;

@interface CIMConnectorManager : NSObject<GCDAsyncSocketDelegate>

- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate;

@property(nonatomic, copy) NSString *userName;
@property (readwrite, copy) NSString *hostName;
@property (readwrite, assign) UInt16 hostPort;
@property (readwrite, assign) NSTimeInterval keepAliveInterval;

@property (readwrite, assign) char keepAliveWhitespaceCharacter;

/**
 * Returns the total number of bytes bytes sent/received by the connector.
 *
 * The functionality may optionaly be changed to count only the current socket connection.
 * @see resetByteCountPerConnection
 **/
@property (readonly) uint64_t numberOfBytesSent;
@property (readonly) uint64_t numberOfBytesReceived;

/**
 * Same as the individual properties,
 * but provides a way to fetch them in one atomic operation.
 **/
- (void)getNumberOfBytesSent:(uint64_t *)bytesSentPtr numberOfBytesReceived:(uint64_t *)bytesReceivedPtr;

/**
 * Affects the funtionality of the byte counter.
 *
 * The default value is NO.
 *
 * If set to YES, the byte count will be reset just prior to a new connection (in the connect methods).
 **/
@property (readwrite, assign) BOOL resetByteCountPerConnection;

/**
 * The tag property allows you to associate user defined information with the connector.
 **/
@property (readwrite, strong) id tag;

/**
 * If set, the kCFStreamNetworkServiceTypeVoIP flags will be set on the underlying CFRead/Write streams.
 *
 * The default value is NO.
 **/
@property (readwrite, assign) BOOL enableBackgroundingOnSocket;

#pragma mark - State
/**
 * Returns YES if the connection is closed, and thus no connector is open.
 * If the stream is neither disconnected, nor connected, then a connection is currently being established.
 **/
- (BOOL)isDisconnected;

/**
 * Returns YES is the connection is currently connecting
 **/
- (BOOL)isConnecting;

/**
 * Returns YES if the connection is open, and the connector has been properly established.
 * If the connector is neither disconnected, nor connected, then a connection is currently being established.
 *
 * If this method returns YES, then it is ready for you to start sending and receiving elements.
 **/
- (BOOL)isConnected;

#pragma mark - Connect & Disconnect
/**
 * Connects to the configured hostName on the configured hostPort.
 * The timeout is optional. To not time out use CIMConnectorTimeoutNone.
 * If the hostName are not set, this method will return NO and set the error parameter.
 **/
- (BOOL)connectWithTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr;

/**
 * Disconnects from the remote host by closing the underlying TCP socket connection.
 *
 * This method is synchronous.
 * Meaning that the disconnect will happen immediately, even if there are pending elements yet to be sent.
 *
 * The cimConnectorDidDisconnect:withError: delegate method will immediately be dispatched onto the delegate queue.
 **/
- (void)disconnect;

- (void)disconnectAfterSending;

#pragma mark - Server Info

- (NSXMLElement *)rootElement;

#pragma mark - Sending
/**
 * Sends the given XML element.
 * If the connector is not yet connected, this method does nothing.
 **/
- (void)sendElement:(NSXMLElement *)element;

/**
 * Just like the sendElement: method above,
 * but allows you to receive a receipt that can later be used to verify the element has been sent.
 *
 * If you later want to check to see if the element has been sent:
 *
 * if ([receipt wait:0]) {
 *   // Element has been sent
 * }
 *
 * If you later want to wait until the element has been sent:
 *
 * if ([receipt wait:-1]) {
 *   // Element was sent
 * } else {
 *   // Element failed to send due to disconnection
 * }
 *
 * It is important to understand what it means when [receipt wait:timeout] returns YES.
 * It does NOT mean the server has received the element.
 * It only means the data has been queued for sending in the underlying OS socket buffer.
 *
 * So at this point the OS will do everything in its capacity to send the data to the server,
 * which generally means the server will eventually receive the data.
 * Unless, of course, something horrible happens such as a network failure,
 * or a system crash, or the server crashes, etc.
 *
 * Even if you close the xmpp stream after this point, the OS will still do everything it can to send the data.
 **/
- (void)sendElement:(NSXMLElement *)element andGetReceipt:(CIMElementReceipt **)receiptPtr;

#pragma mark Module - Plug-In System

/**
 * The CIMModule class automatically invokes these methods when it is activated/deactivated.
 *
 * The registerModule method registers the module with the connector.
 * If there are any other modules that have requested to be automatically added as delegates to modules of this type,
 * then those modules are automatically added as delegates during the asynchronous execution of this method.
 *
 * The registerModule method is asynchronous.
 *
 * The unregisterModule method unregisters the module with the connector,
 * and automatically removes it as a delegate of any other module.
 *
 * The unregisterModule method is fully synchronous.
 * That is, after this method returns, the module will not be scheduled in any more delegate calls from other modules.
 * However, if the module was already scheduled in an existing asynchronous delegate call from another module,
 * the scheduled delegate invocation remains queued and will fire in the near future.
 * Since the delegate invocation is already queued,
 * the module's retainCount has been incremented,
 * and the module will not be deallocated until after the delegate invocation has fired.
 **/
- (void)registerModule:(CIMModule *)module;
- (void)unregisterModule:(CIMModule *)module;

/**
 * Automatically registers the given delegate with all current and future registered modules of the given class.
 *
 * That is, the given delegate will be added to the delegate list ([module addDelegate:delegate delegateQueue:dq]) to
 * all current and future registered modules that respond YES to [module isKindOfClass:aClass].
 *
 * This method is used by modules to automatically integrate with other modules.
 *
 * This may also be useful to clients, for example, to add a delegate to instances of something like ChatRoom,
 * where there may be multiple instances of the module that get created during the course of an session.
 *
 * If you auto register on multiple queues, you can remove all registrations with a single
 * call to removeAutoDelegate::: by passing NULL as the 'dq' parameter.
 *
 * If you auto register for multiple classes, you can remove all registrations with a single
 * call to removeAutoDelegate::: by passing nil as the 'aClass' parameter.
 **/
- (void)autoAddDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue toModulesOfClass:(Class)aClass;
- (void)removeAutoDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue fromModulesOfClass:(Class)aClass;
/**
 * Allows for enumeration of the currently registered modules.
 *
 * This may be useful if the stream needs to be queried for modules of a particular type.
 **/
- (void)enumerateModulesWithBlock:(void (^)(CIMModule *module, NSUInteger idx, BOOL *stop))block;

/**
 * Allows for enumeration of the currently registered modules that are a kind of Class.
 * idx is in relation to all modules not just those of the given class.
 **/
- (void)enumerateModulesOfClass:(Class)aClass withBlock:(void (^)(CIMModule *module, NSUInteger idx, BOOL *stop))block;

#pragma mark - Utilities
+ (NSString *)generateUUID;
- (NSString *)generateUUID;

@end

#pragma mark -
@interface CIMElementReceipt : NSObject
{
    uint32_t atomicFlags;
    dispatch_semaphore_t semaphore;
}

/**
 * Element receipts allow you to check to see if the element has been sent.
 * The timeout parameter allows you to do any of the following:
 *
 * - Do an instantaneous check (pass timeout == 0)
 * - Wait until the element has been sent (pass timeout < 0)
 * - Wait up to a certain amount of time (pass timeout > 0)
 *
 * It is important to understand what it means when [receipt wait:timeout] returns YES.
 * It does NOT mean the server has received the element.
 * It only means the data has been queued for sending in the underlying OS socket buffer.
 *
 * So at this point the OS will do everything in its capacity to send the data to the server,
 * which generally means the server will eventually receive the data.
 * Unless, of course, something horrible happens such as a network failure,
 * or a system crash, or the server crashes, etc.
 *
 * Even if you close the xmpp stream after this point, the OS will still do everything it can to send the data.
 **/
- (BOOL)wait:(NSTimeInterval)timeout;

@end

@protocol CIMConnectorDelegate <NSObject>
@optional

- (void)cimConnectorWillConnect:(CIMConnectorManager *)sender;

- (void)cimConnector:(CIMConnectorManager *)sender socketDidConnect:(GCDAsyncSocket *)socket;

- (void)cimConnectorDidStartNegotiation:(CIMConnectorManager *)sender;

- (void)cimConnectorWillBind:(CIMConnectorManager *)sender;

- (void)cimConnectorDidConnect:(CIMConnectorManager *)sender;

- (CIMReplyBody *)cimConnector:(CIMConnectorManager *)sender willReceiveReplyBody:(CIMReplyBody *)replyBody;
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveReplyBody:(CIMReplyBody *)replyBody;

- (CIMMessage *)cimConnector:(CIMConnectorManager *)sender willReceiveMessage:(CIMMessage *)message;
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveMessage:(CIMMessage *)message;
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveError:(NSXMLElement *)error;

- (CIMMessage *)cimConnector:(CIMConnectorManager *)sender willSendMessage:(CIMMessage *)message;
- (void)cimConnector:(CIMConnectorManager *)sender didSendMessage:(CIMMessage *)message;
- (void)cimConnector:(CIMConnectorManager *)sender didFailToSendMessage:(CIMMessage *)message error:(NSError *)error;

- (void)cimConnectorWasToldToDisconnect:(CIMConnectorManager *)sender;

- (void)cimConnectorConnectDidTimeout:(CIMConnectorManager *)sender;

- (void)cimConnectorDidDisconnect:(CIMConnectorManager *)sender withError:(NSError *)error;

- (void)cimConnector:(CIMConnectorManager *)sender didRegisterModule:(id)module;
- (void)cimConnector:(CIMConnectorManager *)sender willUnregisterModule:(id)module;

- (void)cimConnector:(CIMConnectorManager *)sender didSendCustomElement:(NSXMLElement *)element;
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveCustomElement:(NSXMLElement *)element;

@end