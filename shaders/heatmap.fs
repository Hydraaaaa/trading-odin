#version 330

in vec2 fragTexCoord;
out vec4 fragColor;

uniform sampler2D texture0; // Grayscale input texture

void main()
{
    float grayscale = texture(texture0, fragTexCoord).r; // Read grayscale value
    fragColor = vec4(1.0, 1.0, 1.0, grayscale); // Set alpha to grayscale value
}
