#import "../preview/extension/ParquetPreview.h"

void ParquetHostPrepare(id controller, NSURL *url, void (^handler)(NSError *error)) {
    SEL selector = @selector(preparePreviewOfFileAtURL:completionHandler:);
    if (![controller respondsToSelector:selector]) {
        handler([NSError errorWithDomain:@"com.rkrug.parquetindexer.preview"
                                     code:3
                                 userInfo:@{NSLocalizedDescriptionKey: @"preparePreviewOfFileAtURL:completionHandler: is not visible to Objective-C"}]);
        return;
    }
    void (*implementation)(id, SEL, NSURL *, void (^)(NSError *)) =
        (void *)[controller methodForSelector:selector];
    implementation(controller, selector, url, handler);
}
