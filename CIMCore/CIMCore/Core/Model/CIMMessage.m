//
//  CIMMessage.m
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import "CIMMessage.h"
//#import <objc/runtime.h>

@implementation CIMMessage

//<?xml version="1.0" encoding="UTF-8"?><message><mid>null</mid><type>2</type><title></title><content><![CDATA[sdfsdfsfsf]]></content><file></file><fileType></fileType><sender>system</sender><receiver>xmpptest</receiver><format>txt</format><timestamp>1421053629877</timestamp></message>
+ (CIMMessage *)messageFromElement:(NSXMLElement *)element
{
//    object_setClass(element, [CIMMessage class]);
    
    return (CIMMessage *)element;
}

@end
