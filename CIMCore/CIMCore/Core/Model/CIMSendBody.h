//
//  CIMSendBody.h
//  CIMCore
//
//  Created by Charles on 15/1/12.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMElement.h"

@interface CIMSendBody : CIMElement

@property(nonatomic,strong)NSString *key;

@property(nonatomic,readonly)NSString *timestamp;

@property(nonatomic,readonly)NSDictionary *data;

-(void)addDataAttribute:(NSDictionary*)data;

@end
