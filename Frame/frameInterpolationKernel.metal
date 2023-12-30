//
//  frame.metal
//  Frame
//
//  Created by Mohan Singh Thagunna on 30/12/2023.
//

#include <metal_stdlib>
using namespace metal;

kernel void frameInterpolationKernel(texture2d<float, access::read> previousFrame [[texture(0)]],
                                     texture2d<float, access::read> nextFrame [[texture(1)]],
                                     texture2d<float, access::write> interpolatedFrame [[texture(2)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    // Check if the thread is within the texture bounds
    if (gid.x >= interpolatedFrame.get_width() || gid.y >= interpolatedFrame.get_height()) {
        return;
    }

    // Read the pixel colors from the previous and next frames
    float4 colorPrev = previousFrame.read(gid);
    float4 colorNext = nextFrame.read(gid);

    // Perform linear interpolation between the two colors
    float4 interpolatedColor = mix(colorPrev, colorNext, 0.5f);

    // Write the interpolated color to the output texture
    interpolatedFrame.write(interpolatedColor, gid);
}
