#!/bin/bash

# Setting folders
SHADER_DIR="shaders"
OUTPUT_DIR="shaders/compiled" 

# Check that shader folder exists
mkdir -p "$OUTPUT_DIR"

echo "=== Starting shader conversion ==="
any_compiled=false

for file in "$SHADER_DIR"/*; do
    # Bypass ready .spv files and folders
    if [[ "$file" == *.spv ]] || [ -d "$file" ]; then
        continue
    fi

    filename=$(basename "$file")
    # Removing end of file for final naming (exc. mesh.mesh -> mesh)
    # If you use three part file names in future, this takes only the first part of name.
    basename="${filename%%.*}"
    output_file="$OUTPUT_DIR/$basename.spv"

    # Has file changed?
    # If .spv exists and it's newer than shader file, bypass.
    if [ -f "$output_file" ] && [ "$output_file" -nt "$file" ]; then
        continue
    fi

    # Change filename to lower capitals for identifying shader type
    lower_filename=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
    any_compiled=true

    # Identifying shader type by name
    if [[ "$lower_filename" == *".mesh"* ]]; then
        echo "Converting Mesh Shader: $filename -> $basename.spv"
        glslangValidator -V --target-env vulkan1.3 -S mesh "$file" -o "$OUTPUT_DIR/$basename.spv"
        
    elif [[ "$lower_filename" == *".vert"* ]]; then
        echo "Converting Vertex Shader: $filename -> $basename.spv"
        glslangValidator -V --target-env vulkan1.3 -S vert "$file" -o "$OUTPUT_DIR/$basename.spv"

    elif [[ "$lower_filename" == *".frag"* ]]; then
        echo "Converting Fragment Shader: $filename -> $basename.spv"
        glslangValidator -V --target-env vulkan1.3 "$file" -o "$OUTPUT_DIR/$basename.spv"
        
    elif [[ "$lower_filename" == *".task"* ]]; then
        echo "Converting Task Shader: $filename -> $basename.spv"
        glslangValidator -V --target-env vulkan1.3 -S task "$file" -o "$OUTPUT_DIR/$basename.spv"
        
    else
        echo "Unknown shader-type, bypassing: $filename"
    fi
done

if [ "$any_compiled" = false ]; then
    echo "All shaders are already up-to-date."
else
    echo "=== Conversion finished ==="
fi