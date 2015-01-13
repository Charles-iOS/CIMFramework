//
//  CIMMessage.h
//  CIMCore
//
//  Created by Charles on 15/1/6.
//  Copyright (c) 2015年 Charles. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CIMElement.h"
#import "NSXMLElement+XMPP.h"

@interface CIMMessage : CIMElement

// Converts an NSXMLElement to an XMPPMessage element in place (no memory allocations or copying)
+ (CIMMessage *)messageFromElement:(NSXMLElement *)element;

@end
