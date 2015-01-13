//
//  CIMCoreTests.m
//  CIMCoreTests
//
//  Created by Charles on 15/1/11.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import "CIM.h"
#import "CIMReplyBody.h"
#import "CIMSendBody.h"

@interface CIMCoreTests : XCTestCase

@end

@implementation CIMCoreTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testExample {
    // This is an example of a functional test case.
//    XCTAssert(YES, @"Pass");
//    NSError *error = nil;
//    CIMReplyBody *replyBody = [CIMReplyBody replyBodyFromXMLString:@"<reply><key>client_bind</key><timestamp>1421053608456</timestamp><code>200</code><data></data></reply>" error:&error];
//    NSLog(@"%@",[replyBody compactXMLString]);
    CIMConnectorManager *connector = [[CIMConnectorManager alloc]init];
    [connector addDelegate:self delegateQueue:dispatch_get_main_queue()];
    [connector setHostName:@"10.100.20.12"];
    NSError *error = nil;
    if (![connector connectWithTimeout:CIMConnectorTimeoutNone error:&error])
    {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error connecting"
                                                            message:@"See console for error details."
                                                           delegate:nil
                                                  cancelButtonTitle:@"Ok"
                                                  otherButtonTitles:nil];
        [alertView show];
    }
    CFRunLoopRun();
}

- (void)cimConnectorWillConnect:(CIMConnectorManager *)sender
{
    
}
- (void)cimConnectorDidStartNegotiation:(CIMConnectorManager *)sender
{
    
}
- (void)cimConnectorDidConnect:(CIMConnectorManager *)sender
{
    
}
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveMessage:(CIMMessage *)message
{
    
}
- (void)cimConnector:(CIMConnectorManager *)sender didReceiveError:(NSXMLElement *)error
{
    
}
- (void)cimConnectorConnectDidTimeout:(CIMConnectorManager *)sender
{
    
}
- (void)cimConnectorDidDisconnect:(CIMConnectorManager *)sender withError:(NSError *)error
{
    
}

- (void)testPerformanceExample {
    // This is an example of a performance test case.
    [self measureBlock:^{
        CIMConnectorManager *connector = [[CIMConnectorManager alloc]init];
        [connector addDelegate:self delegateQueue:dispatch_get_main_queue()];
        [connector setHostName:@"10.100.20.12"];
        NSError *error = nil;
        if (![connector connectWithTimeout:CIMConnectorTimeoutNone error:&error])
        {
            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error connecting"
                                                                message:@"See console for error details."
                                                               delegate:nil
                                                      cancelButtonTitle:@"Ok"
                                                      otherButtonTitles:nil];
            [alertView show];
        }
        // Put the code you want to measure the time of here.
    }];
}

@end
