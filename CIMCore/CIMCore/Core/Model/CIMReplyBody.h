//
//  CIMReplyBody.h
//  CIMCore
//
//  Created by Charles on 15/1/12.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMElement.h"

@interface CIMReplyBody : CIMElement

@property(nonatomic,readonly)NSString *key;

@property(nonatomic,readonly)NSString *timestamp;

@property(nonatomic,readonly)NSString *code;

@property(nonatomic,readonly)NSString *message;

@property(nonatomic,readonly)NSDictionary *data;

//+ (CIMReplyBody*)replyBodyFromXMLString:(NSString *)string error:(NSError *__autoreleasing *)error;

@end
