#import "ParquetPreview.h"

NSError *ParquetCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name.length > 0 ? exception.name : @"NSException";
        NSString *reason = exception.reason.length > 0 ? exception.reason : @"";
        return [NSError errorWithDomain:@"com.rkrug.parquetindexer.preview"
                                    code:1
                                userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason]
        }];
    }
}
