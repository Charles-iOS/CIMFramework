//
//  CIMReplyBody.m
//  CIMCore
//
//  Created by Charles on 15/1/12.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMReplyBody.h"
#import "NSXMLElement+XMPP.h"

@interface CIMReplyBody ()

@property(nonatomic,strong)NSString *key;

@property(nonatomic,strong)NSString *timestamp;

@property(nonatomic,strong)NSString *code;

@property(nonatomic,strong)NSString *message;

@property(nonatomic,strong)NSDictionary *data;

@end

@implementation CIMReplyBody

//<?xml version="1.0" encoding="UTF-8"?><reply><key>client_bind</key><timestamp>1421053608456</timestamp><code>200</code><data></data></reply>
//- (instancetype)initWithXMLString:(NSString *)string error:(NSError *__autoreleasing *)error
//{
//    self = [super initWithXMLString:string error:error];
//    if (self) {
//        _key = [self attributeStringValueForName:@"key"];
//        _timestamp = [self attributeStringValueForName:@"timestamp"];
//        _code = [self attributeStringValueForName:@"code"];
//        _message = [self attributeStringValueForName:@"message"];
//        NSXMLElement *dataElement = [self elementForName:@"data"];
//        NSMutableDictionary *d = [NSMutableDictionary new];
//        for (NSXMLElement *e in dataElement.children) {
//            [d setObject:e.stringValue forKey:e.name];
//        }
//        _data = [NSDictionary dictionaryWithDictionary:d];
//    }
//    return self;
//}

//+ (CIMReplyBody*)replyBodyFromXMLString:(NSString *)string error:(NSError *__autoreleasing *)error
//{
//    NSXMLDocument *doc = [[NSXMLDocument alloc]initWithXMLString:string options:DDXMLDocumentKind error:error];
//    CIMReplyBody *replyBody = (CIMReplyBody*)doc.rootElement;
//    replyBody.key = [replyBody attributeStringValueForName:@"key"];
//    replyBody.timestamp = [replyBody attributeStringValueForName:@"timestamp"];
//    replyBody.code = [replyBody attributeStringValueForName:@"code"];
//    replyBody.message = [replyBody attributeStringValueForName:@"message"];
//    NSXMLElement *dataElement = [replyBody elementForName:@"data"];
//    NSMutableDictionary *d = [NSMutableDictionary new];
//    for (NSXMLElement *e in dataElement.children) {
//        [d setObject:e.stringValue forKey:e.name];
//    }
//    replyBody.data = [NSDictionary dictionaryWithDictionary:d];
//    return replyBody;
//}

@end
