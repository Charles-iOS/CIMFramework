//
//  CIMSendBody.m
//  CIMCore
//
//  Created by Charles on 15/1/12.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMSendBody.h"
#import "NSXMLElement+XMPP.h"

@implementation CIMSendBody
{
    NSString *key;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSXMLElement *sent = [NSXMLElement elementWithName:@"sent"];
        [self addChild:sent];
        [sent addAttributeWithName:@"timestamp" stringValue:[NSString stringWithFormat:@"%.0f",[[NSDate date] timeIntervalSince1970]]];
    }
    return self;
}

-(void)setKey:(NSString *)key_
{
    NSXMLElement *sent = [self elementForName:@"sent"];
    //key = [sent attributeStringValueForName:@"key"];
    if (!key) {
        [sent addAttributeWithName:@"key" stringValue:key_];
    }
    else{
        NSXMLElement *keyElement = (NSXMLElement*)[sent attributeForName:@"key"];
        [keyElement setStringValue:key_];
    }
    key = key_;
}

-(NSString *)key
{
    return key;
}

/*
 StringBuffer buffer = new StringBuffer();
 buffer.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
 buffer.append("<sent>");
 buffer.append("<key>").append(key).append("</key>");
 buffer.append("<timestamp>").append(timestamp).append("</timestamp>");
 buffer.append("<data>");
 for (String key : data.keySet()) {
 buffer.append("<" + key + ">").append(data.get(key)).append(
 "</" + key + ">");
 }
 buffer.append("</data>");
 buffer.append("</sent>");
 */
/*
 @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><sent><key>client_bind</key><timestamp>1420344757425</timestamp><data><device>MI 2</device><channel>android<\channel><account>admin</account><deviceId>904d921235ab3e4981a3055015e4a3fd</deviceId></data><\sent>"
 */
//生成<body>
//            NSXMLElement *sent = [NSXMLElement elementWithName:@"sent"];
//
////            [sent addAttributeWithName:@"key" stringValue:@"client_bind"];
//            NSXMLElement *requestKey = [NSXMLElement elementWithName:@"key" stringValue:@"client_bind"];
//            NSXMLElement *timestamp = [NSXMLElement elementWithName:@"timestamp" stringValue:[NSString stringWithFormat:@"%.0f",[[NSDate date] timeIntervalSince1970]]];
////            [body addAttributeWithName:@"timestamp" stringValue:[NSString stringWithFormat:@"%.0f",[[NSDate date] timeIntervalSince1970]]];
//            [sent addChild:requestKey];
//            [sent addChild:timestamp];
////            [body setStringValue:message];
-(void)addDataAttribute:(NSDictionary *)data
{
    NSXMLElement *dataElement = [self elementForName:@"data"];
    if (!data) {
        data = [NSXMLElement elementWithName:@"data"];
        [self addChild:dataElement];
    }
    for (NSString *key_ in data.allKeys) {
        [dataElement addAttributeWithName:key_ stringValue:data[key_]];
    }
}

@end
