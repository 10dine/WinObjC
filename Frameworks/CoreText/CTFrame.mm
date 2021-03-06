//******************************************************************************
//
// Copyright (c) Microsoft. All rights reserved.
//
// This code is licensed under the MIT License (MIT).
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//******************************************************************************

#import <CoreText/CTFrame.h>
#import <StubReturn.h>

#import "DWriteWrapper_CoreText.h"
#import "CoreTextInternal.h"
#import "CGContextInternal.h"
#import "CGPathInternal.h"

const CFStringRef kCTFrameProgressionAttributeName = static_cast<CFStringRef>(@"kCTFrameProgressionAttributeName");
const CFStringRef kCTFramePathFillRuleAttributeName = static_cast<CFStringRef>(@"kCTFramePathFillRuleAttributeName");
const CFStringRef kCTFramePathWidthAttributeName = static_cast<CFStringRef>(@"kCTFramePathWidthAttributeName");
const CFStringRef kCTFrameClippingPathsAttributeName = static_cast<CFStringRef>(@"kCTFrameClippingPathsAttributeName");
const CFStringRef kCTFramePathClippingPathAttributeName = static_cast<CFStringRef>(@"kCTFramePathClippingPathAttributeName");

@implementation _CTFrame : NSObject
- (instancetype)init {
    if ([super init]) {
        _lines.attach([NSMutableArray new]);
    }

    return self;
}

@end

/**
 @Status Interoperable
 @Notes
*/
CFRange CTFrameGetStringRange(CTFrameRef frame) {
    _CTFrame* framePtr = static_cast<_CTFrame*>(frame);
    CFIndex count = 0;
    if (framePtr) {
        for (_CTLine* line in static_cast<id<NSFastEnumeration>>(framePtr->_lines)) {
            count += line->_strRange.length;
        }
    }
    return CFRangeMake(0, count);
}

/**
 @Status Interoperable
 @Notes
*/
CFRange CTFrameGetVisibleStringRange(CTFrameRef frame) {
    _CTFrame* framePtr = static_cast<_CTFrame*>(frame);
    CFIndex count = 0;
    if (framePtr) {
        for (size_t i = 0; i < framePtr->_lineOrigins.size(); ++i) {
            if (framePtr->_lineOrigins[i].y < framePtr->_frameRect.size.height) {
                _CTLine* line = static_cast<_CTLine*>([framePtr->_lines objectAtIndex:i]);
                count += line->_strRange.length;
            }
        }
    }
    return CFRangeMake(0, count);
}

/**
 @Status Interoperable
 @Notes
*/
CGPathRef CTFrameGetPath(CTFrameRef frame) {
    return frame ? static_cast<_CTFrame*>(frame)->_path.get() : nil;
}

/**
 @Status Stub
 @Notes
*/
CFDictionaryRef CTFrameGetFrameAttributes(CTFrameRef frame) {
    UNIMPLEMENTED();
    return StubReturn();
}

/**
 @Status Interoperable
*/
CFArrayRef CTFrameGetLines(CTFrameRef frame) {
    return frame ? static_cast<CFArrayRef>(static_cast<_CTFrame*>(frame)->_lines.get()) : nil;
}

/**
 @Status Interoperable
*/
void CTFrameGetLineOrigins(CTFrameRef frameRef, CFRange range, CGPoint origins[]) {
    _CTFrame* frame = static_cast<_CTFrame*>(frameRef);
    if (frame) {
        _boundedCopy(range, frame->_lineOrigins.size(), frame->_lineOrigins.data(), origins);
    }
}

/**
 @Status Interoperable
*/
void CTFrameDraw(CTFrameRef frameRef, CGContextRef ctx) {
    _CTFrame* frame = static_cast<_CTFrame*>(frameRef);
    if (frame && ctx) {
        // Need to invert and translate coordinates so frame draws from top-left
        CGContextSaveGState(ctx);
        CGRect boundingRect = CGPathGetBoundingBox(frame->_path.get());
        CGContextTranslateCTM(ctx, 0, boundingRect.size.height);

        // Invert Text Matrix and CTM so glyphs are drawn in correct orientation and correct position
        CGAffineTransform textMatrix = CGContextGetTextMatrix(ctx);
        CGContextSetTextMatrix(
            ctx, CGAffineTransformMake(textMatrix.a, -textMatrix.b, textMatrix.c, -textMatrix.d, textMatrix.tx, textMatrix.ty));
        CGContextScaleCTM(ctx, 1.0f, -1.0f);

        _CGContextPushBeginDraw(ctx);
        auto popEnd = wil::ScopeExit([ctx]() { _CGContextPopEndDraw(ctx); });

        for (size_t i = 0; i < frame->_lineOrigins.size() && (frame->_lineOrigins[i].y < frame->_frameRect.size.height); ++i) {
            _CTLine* line = static_cast<_CTLine*>([frame->_lines objectAtIndex:i]);
            CGContextSetTextPosition(ctx, frame->_lineOrigins[i].x, frame->_lineOrigins[i].y);
            CTLineDraw(static_cast<CTLineRef>(line), ctx);
        }

        // Restore CTM and Text Matrix to values before we modified them
        CGContextRestoreGState(ctx);
        CGContextSetTextMatrix(ctx, textMatrix);
    }
}

/**
 @Status Stub
 @Notes
*/
CFTypeID CTFrameGetTypeID() {
    UNIMPLEMENTED();
    return StubReturn();
}

// Convenience private function for NSString+UIKitAdditions
CGSize _CTFrameGetSize(CTFrameRef frame) {
    return frame ? static_cast<_CTFrame*>(frame)->_frameRect.size : CGSize{};
}
