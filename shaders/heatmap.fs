#version 330

in vec2 fragTexCoord;
out vec4 fragColor;

uniform sampler2D texture0; // Grayscale input texture

void main()
{
    float opacity = texture(texture0, fragTexCoord).r; // Read grayscale value
    float gb = 1.0 - step(1.0, opacity); // If grayscale is 1.0, green and blue will be 0

    fragColor = vec4(1.0, gb, gb, opacity);
}
