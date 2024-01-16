// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// This logic is not foolproof and may result in memory-leaks, when possible we should look to remove this
// and use the native C++ <-> Swift interoperability coming with Swift 5.9
//
// This solution was sourced from the following link, for more information please refer to this thread:
// https://forums.swift.org/t/pitch-a-swift-representation-for-thrown-and-caught-exceptions/54583

#import "CExceptionHelper.h"
#include <exception>

@implementation CExceptionHelper

+ (BOOL)performSafely:(noEscape void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
    try {
        tryBlock();
        return YES;
    }
    catch(NSException* e) {
        *error = [[NSError alloc] initWithDomain:e.name code:-1 userInfo:e.userInfo];
        return NO;
    }
    catch (std::exception& e) {
        NSString* what = [NSString stringWithUTF8String: e.what()];
        
        if (what != nil) {
            NSDictionary* userInfo = @{NSLocalizedDescriptionKey : what};
            *error = [[NSError alloc] initWithDomain:@"cpp_exception" code:-2 userInfo:userInfo];
        }
        else {
            NSDictionary* userInfo = @{NSLocalizedDescriptionKey : @"unknown exception"};
            *error = [[NSError alloc] initWithDomain:@"cpp_exception" code:-2 userInfo:userInfo];
        }
        return NO;
    }
    catch(...) {
        NSDictionary* userInfo = @{NSLocalizedDescriptionKey:@"Other C++ exception"};
        *error = [[NSError alloc] initWithDomain:@"cpp_exception" code:-3 userInfo:userInfo];
        return NO;
    }
}

@end
