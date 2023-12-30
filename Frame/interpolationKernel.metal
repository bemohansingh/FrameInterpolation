//
//  interpolationKernel.metal
//  Frame
//
//  Created by Mohan Singh Thagunna on 30/12/2023.
//

#include <metal_stdlib>
using namespace metal;

kernel void interpolationKernel(texture2d<float, access::read> texture1 [[texture(0)]],
                                texture2d<float, access::read> texture2 [[texture(1)]],
                                texture2d<float, access::write> outputTexture [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    // Ensure we don't read or write outside the texture bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Read pixel colors from both textures
    float4 color1 = texture1.read(gid);
    float4 color2 = texture2.read(gid);

    // Perform simple linear interpolation
    float4 interpolatedColor = mix(color1, color2, 0.5);

    // Write the interpolated color to the output texture
    outputTexture.write(interpolatedColor, gid);
}

