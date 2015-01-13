//
//  CIMParser.m
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMParser.h"

@interface NSData (type)

-(BOOL)isJPEG;

-(BOOL)isPNG;

@end

@implementation NSData (type)

-(BOOL)isJPEG
{
    if (self.length > 4)
    {
        unsigned char buffer[4];
        [self getBytes:&buffer length:4];
        
        return buffer[0]==0xff &&
        buffer[1]==0xd8 &&
        buffer[2]==0xff &&
        buffer[3]==0xe0;
    }
    return NO;
}

-(BOOL)isPNG
{
    if (self.length > 4)
    {
        unsigned char buffer[4];
        [self getBytes:&buffer length:4];
        
        return buffer[0]==0x89 &&
        buffer[1]==0x50 &&
        buffer[2]==0x4e &&
        buffer[3]==0x47;
    }
    
    return NO;
}

@end

@interface CIMParser ()<NSXMLParserDelegate>
{
    dispatch_queue_t delegateQueue;
    
    dispatch_queue_t parserQueue;
    void *cimParserQueueTag;
}

@property(nonatomic,strong) DDXMLElement *currentElement;
@property(nonatomic,strong) NSString *currentElementName;
@property(nonatomic,strong) DDXMLElement *parentElement;
@property(nonatomic,weak)id<CIMParserDelegate> delegate;

@end

@implementation CIMParser

- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq
{
    return [self initWithDelegate:aDelegate delegateQueue:dq parserQueue:NULL];
}

- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq parserQueue:(dispatch_queue_t)pq
{
    if ((self = [super init]))
    {
        _delegate = aDelegate;
        delegateQueue = dq;
        
        if (pq) {
            parserQueue = pq;
        }
        else {
            parserQueue = dispatch_queue_create("cim.parser", NULL);
        }
        
        cimParserQueueTag = &cimParserQueueTag;
        dispatch_queue_set_specific(parserQueue, cimParserQueueTag, cimParserQueueTag, NULL);
    }
    return self;
}

- (void)dealloc
{
    
}

- (void)setDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
    dispatch_block_t block = ^{
        
        _delegate = newDelegate;
        
        delegateQueue = newDelegateQueue;
    };
    
    if (dispatch_get_specific(cimParserQueueTag))
        block();
    else
        dispatch_async(parserQueue, block);
}

-(BOOL)parseData:(NSData *)data
{
    if (data.length>2) {
        //CIM SERVER MESSAGE_SEPARATE
        char buffer[1];
        [data getBytes:&buffer range:NSMakeRange(data.length-1, 1)];
        if (buffer[0] == '\b') {
            data = [data subdataWithRange:NSMakeRange(0, data.length-1)];
        }
    }
    NSXMLParser *parse = [[NSXMLParser alloc]initWithData:data];
    [parse setDelegate:self];
    NSString *xml = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"parseData %@",xml);
    return [parse parse];
}

#pragma mark - NSXMLParserDelegate
- (void)parserDidStartDocument:(NSXMLParser *)parser
{
    
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict
{
    self.currentElement = [[DDXMLElement alloc] initWithName:elementName];
    [self.rootElement addChild:self.currentElement];
    if (!self.rootElement) {
        self.rootElement = self.currentElement;
        if (self.delegate&&[self.delegate respondsToSelector:@selector(cimParser:didReadRoot:)]) {
            [self.delegate cimParser:self didReadRoot:self.rootElement];
        }
    }
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
    
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    [self.currentElement setStringValue:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    if (self.delegate&&[self.delegate respondsToSelector:@selector(cimParser:didReadElement:)]) {
        [self.delegate cimParser:self didReadElement:self.currentElement];
    }
    self.currentElement = (DDXMLElement*)self.currentElement.parent;
}

- (void)parserDidEndDocument:(NSXMLParser *)parser
{
    if (self.delegate&&[self.delegate respondsToSelector:@selector(cimParserDidEnd:)]) {
        [self.delegate cimParserDidEnd:self];
    }
    self.rootElement = nil;
    self.currentElement = nil;
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock
{
    if (![CDATABlock isPNG]&&![CDATABlock isJPEG]) {
        NSString *data = [[NSString alloc]initWithData:CDATABlock encoding:NSUTF8StringEncoding];
        [self.currentElement setStringValue:data];
    }
    else{
        
    }
}

@end
