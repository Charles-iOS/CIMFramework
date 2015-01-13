//
//  CIMParser.h
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DDXML.h"

@interface CIMParser : NSObject

@property(nonatomic,strong) DDXMLElement *rootElement;

- (id)initWithDelegate:(id)delegate delegateQueue:(dispatch_queue_t)dq;
- (id)initWithDelegate:(id)delegate delegateQueue:(dispatch_queue_t)dq parserQueue:(dispatch_queue_t)pq;

- (void)setDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;

/**
 * Asynchronously parses the given data.
 * The delegate methods will be dispatch_async'd as events occur.
 **/
-(BOOL)parseData:(NSData *)data;

@end

@protocol CIMParserDelegate <NSObject>
@optional

- (void)cimParser:(CIMParser *)sender didReadRoot:(NSXMLElement *)root;

- (void)cimParser:(CIMParser *)sender didReadElement:(NSXMLElement *)element;

- (void)cimParserDidEnd:(CIMParser *)sender;

- (void)cimParser:(CIMParser *)sender didFail:(NSError *)error;

- (void)cimParserDidParseData:(CIMParser *)sender;

@end