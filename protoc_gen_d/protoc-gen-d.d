module protoc_gen_d;

import google.protobuf;
import google.protobuf.compiler.plugin : CodeGeneratorRequest, CodeGeneratorResponse;
import google.protobuf.descriptor : DescriptorProto, EnumDescriptorProto, FieldDescriptorProto, FileDescriptorProto,
    OneofDescriptorProto;

int main()
{
    import std.algorithm : map;
    import std.array : array;
    import std.range : isInputRange, take, walkLength;
    import std.stdio : stdin, stdout;

    foreach (inputRange; stdin.byChunk(1024 * 1024))
    {
        auto request = inputRange.fromProtobuf!CodeGeneratorRequest;
        auto codeGenerator = new CodeGenerator;

        stdout.rawWrite(codeGenerator.handle(request).toProtobuf.array);
    }

    return 0;
}

class CodeGeneratorException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

class CodeGenerator
{
    private enum indentSize = 4;

    CodeGeneratorResponse handle(CodeGeneratorRequest request)
    {
        import std.algorithm : filter, map;
        import std.array : array;
        import std.conv : to;
        import std.format : format;

        with (request.compilerVersion)
            protocVersion = format!"%d%03d%03d"(major, minor, patch);

        collectedMessageTypes.clear;
        auto response = new CodeGeneratorResponse;
        try
        {
            collectMessageAndEnumTypes(request);
            response.files = request.protoFiles
                .filter!(a => a.package_ != "google.protobuf") // don't generate the well known types
                .map!(a => generate(a)).array;
        }
        catch (CodeGeneratorException generatorException)
        {
            response.error = generatorException.message.to!string;
        }

        return response;
    }

    private void collectMessageAndEnumTypes(CodeGeneratorRequest request)
    {
        void collect(DescriptorProto messageType, string prefix)
        {
            auto absoluteName = prefix ~ "." ~ messageType.name;

            if (absoluteName in collectedMessageTypes)
                return;

            collectedMessageTypes[absoluteName] = messageType;

            foreach (nestedType; messageType.nestedTypes)
                collect(nestedType, absoluteName);

            foreach (enumType; messageType.enumTypes)
                collectedEnumTypes[absoluteName ~ "." ~ enumType.name] = enumType;
        }

        foreach (file; request.protoFiles)
        {
            foreach (messageType; file.messageTypes)
                collect(messageType, file.package_ ? "." ~ file.package_ : "");

            foreach (enumType; file.enumTypes)
                collectedEnumTypes["." ~ enumType.name] = enumType;
        }
    }

    private CodeGeneratorResponse.File generate(FileDescriptorProto fileDescriptor)
    {
        import std.array : replace;
        import std.exception : enforce;

        enforce!CodeGeneratorException(fileDescriptor.syntax == "proto3",
            "Can only generate D code for proto3 .proto files.\n" ~
            "Please add 'syntax = \"proto3\";' to the top of your .proto file.\n");

        auto file = new CodeGeneratorResponse.File;

        file.name = fileDescriptor.moduleName.replace(".", "/") ~ ".d";
        file.content = generateFile(fileDescriptor);

        return file;
    }

    private string generateFile(FileDescriptorProto fileDescriptor)
    {
        import std.array : appender, empty;
        import std.format : format;

        auto result = appender!string;
        result ~= "// Generated by the protocol buffer compiler.  DO NOT EDIT!\n";
        result ~= "// source: %s\n\n".format(fileDescriptor.name);
        result ~= "module %s;\n\n".format(fileDescriptor.moduleName);
        result ~= "import google.protobuf;\n";

        foreach (dependency; fileDescriptor.dependencies)
            result ~= "import %s;\n".format(dependency.moduleName);

        if (!protocVersion.empty)
            result ~= "\nenum protocVersion = %s;\n".format(protocVersion);

        foreach (messageType; fileDescriptor.messageTypes)
            result ~= generateMessage(messageType);

        foreach (enumType; fileDescriptor.enumTypes)
            result ~= generateEnum(enumType);

        return result.data;
    }

    private string generateMessage(DescriptorProto messageType, size_t indent = 0)
    {
        import std.algorithm : canFind, filter, sort;
        import std.array : appender, array;
        import std.format : format;

        // Don't generate MapEntry messages, they are generated as associative arrays
        if (messageType.isMap)
            return "";

        auto result = appender!string;
        result ~= "\n%*s%sclass %s\n".format(indent, "", indent > 0 ? "static " : "", messageType.name.escapeKeywords);
        result ~= "%*s{\n".format(indent, "");

        int[] generatedOneofs;
        foreach (field; messageType.fields.sort!((a, b) => a.number < b.number))
        {
            if (field.oneofIndex < 0)
            {
                result ~= generateField(field, indent + indentSize);
                continue;
            }

            if (generatedOneofs.canFind(field.oneofIndex))
                continue;

            result ~= generateOneof(messageType.oneofDecls[field.oneofIndex],
                messageType.fields.filter!(a => a.oneofIndex == field.oneofIndex).array, indent + indentSize);
            generatedOneofs ~= field.oneofIndex;
        }

        foreach (nestedType; messageType.nestedTypes)
            result ~= generateMessage(nestedType, indent + indentSize);

        foreach (enumType; messageType.enumTypes)
            result ~= generateEnum(enumType, indent + indentSize);

        result ~= "%*s}\n".format(indent, "");

        return result.data;
    }

    private string generateField(FieldDescriptorProto field, size_t indent, bool printInitializer = true)
    {
        import std.format : format;

        return "%*s@Proto(%s) %s %s%s;\n".format(indent, "", fieldProtoFields(field), typeName(field),
            field.name.underscoresToCamelCase(false), printInitializer ? fieldInitializer(field) : "");
    }

    private string generateOneof(OneofDescriptorProto oneof, FieldDescriptorProto[] fields, size_t indent)
    {
        return generateOneofCaseEnum(oneof, fields, indent) ~ generateOneofUnion(oneof, fields, indent);
    }

    private string generateOneofCaseEnum(OneofDescriptorProto oneof, FieldDescriptorProto[] fields, size_t indent)
    {
        import std.format : format;
        import std.array : appender;

        auto result = appender!string;
        result ~= "%*senum %sCase\n".format(indent, "", oneof.name.underscoresToCamelCase(true));
        result ~= "%*s{\n".format(indent, "");
        result ~= "%*s%sNotSet = 0,\n".format(indent + indentSize, "", oneof.name.underscoresToCamelCase(false));
        foreach (field; fields)
            result ~= "%*s%s = %s,\n".format(indent + indentSize, "", field.name.underscoresToCamelCase(false),
                field.number);
        result ~= "%*s}\n".format(indent, "");
        result ~= "%*s%3$sCase _%4$sCase = %3$sCase.%4$sNotSet;\n".format(indent, "",
            oneof.name.underscoresToCamelCase(true), oneof.name.underscoresToCamelCase(false));
        result ~= "%*s@property %3$sCase %4$sCase() { return _%4$sCase; }\n".format(indent, "",
            oneof.name.underscoresToCamelCase(true), oneof.name.underscoresToCamelCase(false));
        result ~= "%*svoid clear%3$s() { _%4$sCase = %3$sCase.%4$sNotSet; }\n".format(indent, "",
            oneof.name.underscoresToCamelCase(true), oneof.name.underscoresToCamelCase(false));

        return result.data;
    }

    private string generateOneofUnion(OneofDescriptorProto oneof, FieldDescriptorProto[] fields, size_t indent)
    {
        import std.format : format;
        import std.array : appender;

        auto result = appender!string;
        result ~= "%*s@Oneof(\"_%sCase\") union\n".format(indent, "", oneof.name.underscoresToCamelCase(false));
        result ~= "%*s{\n".format(indent, "");
        foreach (field; fields)
            result ~= generateOneofField(field, indent + indentSize, field == fields[0]);
        result ~= "%*s}\n".format(indent, "");

        return result.data;
    }

    private string generateOneofField(FieldDescriptorProto field, size_t indent, bool printInitializer)
    {
        import std.format : format;

        return "%*s@Proto(%s) %s _%5$s%6$s; mixin(oneofAccessors!_%5$s);\n".format(indent, "", fieldProtoFields(field),
            typeName(field), field.name.underscoresToCamelCase(false),
            printInitializer ? fieldInitializer(field) : "");
    }

    private string generateEnum(EnumDescriptorProto enumType, size_t indent = 0)
    {
        import std.array : appender, array;
        import std.format : format;

        auto result = appender!string;
        result ~= "\n%*senum %s\n".format(indent, "", enumType.name);
        result ~= "%*s{\n".format(indent, "");

        foreach (value; enumType.values)
            result ~= "%*s%s = %s,\n".format(indent + indentSize, "", value.name.escapeKeywords, value.number);

        result ~= "%*s}\n".format(indent, "");

        return result.data;
    }

    private DescriptorProto messageType(FieldDescriptorProto field)
    {
        return field.typeName in collectedMessageTypes ? collectedMessageTypes[field.typeName] : null;
    }

    private EnumDescriptorProto enumType(FieldDescriptorProto field)
    {
        return field.typeName in collectedEnumTypes ? collectedEnumTypes[field.typeName] : null;
    }

    private Wire wireByField(FieldDescriptorProto field)
    {
        final switch (field.type) with (FieldDescriptorProto.Type)
        {
        case TYPE_BOOL: case TYPE_INT32: case TYPE_UINT32: case TYPE_INT64: case TYPE_UINT64:
        case TYPE_FLOAT: case TYPE_DOUBLE: case TYPE_STRING: case TYPE_BYTES: case TYPE_ENUM:
            return Wire.none;
        case TYPE_MESSAGE:
        {
            auto fieldMessageType = messageType(field);

            if (fieldMessageType !is null && fieldMessageType.isMap)
            {
                Wire keyWire = wireByField(fieldMessageType.fieldByNumber(MapFieldNumber.key));
                Wire valueWire = wireByField(fieldMessageType.fieldByNumber(MapFieldNumber.value));

                return keyWire << 2 | valueWire << 4;
            }
            return Wire.none;
        }
        case TYPE_SINT32: case TYPE_SINT64:
            return Wire.zigzag;
        case TYPE_SFIXED32: case TYPE_FIXED32: case TYPE_SFIXED64: case TYPE_FIXED64:
            return Wire.fixed;
        case TYPE_GROUP: case TYPE_ERROR:
            assert(0, "Invalid field type");
        }
    }

    private string baseTypeName(FieldDescriptorProto field)
    {
        import std.exception : enforce;

        final switch (field.type) with (FieldDescriptorProto.Type)
        {
        case TYPE_BOOL:
            return "bool";
        case TYPE_INT32: case TYPE_SINT32: case TYPE_SFIXED32:
            return "int";
        case TYPE_UINT32: case TYPE_FIXED32:
            return "uint";
        case TYPE_INT64: case TYPE_SINT64: case TYPE_SFIXED64:
            return "long";
        case TYPE_UINT64: case TYPE_FIXED64:
            return "ulong";
        case TYPE_FLOAT:
            return "float";
        case TYPE_DOUBLE:
            return "double";
        case TYPE_STRING:
            return "string";
        case TYPE_BYTES:
            return "bytes";
        case TYPE_MESSAGE:
        {
            auto fieldMessageType = messageType(field);
            enforce!CodeGeneratorException(fieldMessageType !is null, "Field '" ~ field.name ~
                "' has unknown message type " ~ field.typeName ~ "`");
            return fieldMessageType.name;
        }
        case TYPE_ENUM:
        {
            auto fieldEnumType = enumType(field);
            enforce!CodeGeneratorException(fieldEnumType !is null, "Field '" ~ field.name ~
                "' has unknown enum type ' " ~field.typeName ~ "`");
            return fieldEnumType.name;
        }
        case TYPE_GROUP: case TYPE_ERROR:
            assert(0, "Invalid field type");
        }
    }

    string typeName(FieldDescriptorProto field)
    {
        import std.format : format;

        string fieldBaseTypeName = baseTypeName(field);

        auto fieldMessageType = messageType(field);

        if (fieldMessageType !is null && fieldMessageType.isMap)
        {
            auto keyField = fieldMessageType.fieldByNumber(MapFieldNumber.key);
            auto valueField = fieldMessageType.fieldByNumber(MapFieldNumber.value);

            return "%s[%s]".format(baseTypeName(valueField), baseTypeName(keyField));
        }

        if (field.label == FieldDescriptorProto.Label.LABEL_REPEATED)
            return fieldBaseTypeName ~ "[]";
        else
            return fieldBaseTypeName;
    }

    private string fieldProtoFields(FieldDescriptorProto field)
    {
        import std.algorithm : stripRight;
        import std.conv : to;
        import std.range : join;

        return [field.number.to!string, wireByField(field).toString].stripRight("").stripRight("Wire.none").join(", ");
    }

    private string fieldInitializer(FieldDescriptorProto field)
    {
        import std.algorithm : endsWith;
        import std.format : format;

        auto fieldTypeName = typeName(field);
        if (fieldTypeName.endsWith("]"))
            return " = protoDefaultValue!(%s)".format(fieldTypeName);
        else
            return " = protoDefaultValue!%s".format(fieldTypeName);
    }

    private string protocVersion;
    private DescriptorProto[string] collectedMessageTypes;
    private EnumDescriptorProto[string] collectedEnumTypes;
}

private FieldDescriptorProto fieldByNumber(DescriptorProto messageType, int fieldNumber)
{
    import std.algorithm : find;
    import std.array : empty;
    import std.exception : enforce;
    import std.format : format;

    auto result = messageType.fields.find!(a => a.number == fieldNumber);

    enforce!CodeGeneratorException(!result.empty,
        "Message '%s' has no field with tag %s".format(messageType.name, fieldNumber));

    return result[0];
}

private bool isMap(DescriptorProto messageType)
{
    return messageType.options && messageType.options.mapEntry;
}

private enum MapFieldNumber
{
    key = 1,
    value = 2,
}

private enum Wire
{
    none,
    fixed = 1 << 0,
    zigzag = 1 << 1,
    fixed_key = 1 << 2,
    zigzag_key = 1 << 3,
    fixed_value = 1 << 4,
    zigzag_value = 1 << 5,
    fixed_key_fixed_value = fixed_key | fixed_value,
    fixed_key_zigzag_value = fixed_key | zigzag_value,
    zigzag_key_fixed_value = zigzag_key | fixed_value,
    zigzag_key_zigzag_value = zigzag_key | zigzag_value,
}

private string toString(Wire wire)
{
    final switch (wire) with (Wire)
    {
    case none:
        return "Wire.none";
    case fixed:
        return "Wire.fixed";
    case zigzag:
        return "Wire.zigzag";
    case fixed_key:
        return "Wire.fixedKey";
    case zigzag_key:
        return "Wire.zigzagKey";
    case fixed_value:
        return "Wire.fixedValue";
    case zigzag_value:
        return "Wire.zigzagValue";
    case fixed_key_fixed_value:
        return "Wire.fixedKeyFixedValue";
    case fixed_key_zigzag_value:
        return "Wire.fixedKeyZigzagValue";
    case zigzag_key_fixed_value:
        return "Wire.zigzagKeyFixedValue";
    case zigzag_key_zigzag_value:
        return "Wire.zigzagKeyZigzagValue";
    }
}

private string moduleName(FileDescriptorProto fileDescriptor)
{
    import std.array : empty;
    import std.path : baseName;

    string moduleName = fileDescriptor.name.baseName(".proto");

    if (!fileDescriptor.package_.empty)
        moduleName = fileDescriptor.package_ ~ "." ~ moduleName;

    return moduleName.escapeKeywords;
}

private string moduleName(string fileName)
{
    import std.array : replace;
    import std.string : chomp;

    return fileName.chomp(".proto").replace("/", ".");
}

private string underscoresToCamelCase(string input, bool capitalizeNextLetter)
{
    import std.array : appender;

    auto result = appender!string;

    foreach (ubyte c; input)
    {
        if (c == '_')
        {
            capitalizeNextLetter = true;
            continue;
        }

        if ('a' <= c && c <= 'z' && capitalizeNextLetter)
            c += 'A' - 'a';

        result ~= c;
        capitalizeNextLetter = false;
    }

    return result.data.escapeKeywords;
}

private enum string[] keywords = [
    "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool", "break", "byte", "case", "cast", "catch",
    "cdouble", "cent", "cfloat", "char", "class", "const", "continue", "creal", "dchar", "debug", "default",
    "delegate", "delete", "deprecated", "do", "double", "else", "enum", "export", "extern", "false", "final",
    "finally", "float", "for", "foreach", "foreach_reverse", "function", "goto", "idouble", "if", "ifloat",
    "immutable", "import", "in", "inout", "int", "interface", "invariant", "ireal", "is", "lazy", "long", "macro",
    "mixin", "module", "new", "nothrow", "null", "out", "override", "package", "pragma", "private", "protected",
    "public", "pure", "real", "ref", "return", "scope", "shared", "short", "static", "struct", "super", "switch",
    "synchronized", "template", "this", "throw", "true", "try", "typedef", "typeid", "typeof", "ubyte", "ucent",
    "uint", "ulong", "union", "unittest", "ushort", "version", "void", "volatile", "wchar", "while", "with",
    "__FILE__", "__MODULE__", "__LINE__", "__FUNCTION__", "__PRETTY_FUNCTION__", "__gshared", "__traits", "__vector",
    "__parameters", "string", "wstring", "dstring", "size_t", "ptrdiff_t", "__DATE__", "__EOF__", "__TIME__",
    "__TIMESTAMP__", "__VENDOR__", "__VERSION__",
];

private string escapeKeywords(string input, string separator = ".")
{
    import std.algorithm : canFind, joiner, map, splitter;
    import std.conv : to;

    return input.splitter(separator).map!(a => keywords.canFind(a) ? a ~ '_' : a).joiner(separator).to!string;
}
