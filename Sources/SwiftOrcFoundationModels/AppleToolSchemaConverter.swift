import FoundationModels
import SwiftOrc

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum AppleToolSchemaConverter {
    static func convertResponse(
        _ schema: LanguageModelJSONSchema
    ) throws -> GenerationSchema {
        do {
            return try convert(
                LanguageModelToolDefinition(
                    name: schema.name,
                    description: schema.description ?? "Structured response.",
                    parameters: schema.schema,
                    strict: schema.strict
                )
            )
        } catch let error as AppleFoundationModelToolBridgeError {
            guard case let .invalidSchema(_, path, reason) = error else {
                throw error
            }
            throw AppleFoundationModelError.invalidResponseSchema(
                name: schema.name,
                path: path,
                reason: reason
            )
        }
    }

    static func convert(
        _ definition: LanguageModelToolDefinition
    ) throws -> GenerationSchema {
        let root = try dynamicSchema(
            definition.parameters,
            tool: definition.name,
            path: "$",
            schemaName: "\(definition.name)_arguments"
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(
        _ schema: JSONValue,
        tool: String,
        path: String,
        schemaName: String
    ) throws -> DynamicGenerationSchema {
        guard case let .object(values) = schema else {
            throw error(tool, path, "Schema must be a JSON object.")
        }

        let schemaType = try schemaType(
            values["type"],
            tool: tool,
            path: path
        )
        let converted: DynamicGenerationSchema
        switch schemaType.name {
        case "object":
            guard case let .object(properties)? = values["properties"] else {
                throw error(tool, path, "Object schema requires properties.")
            }
            let required = try requiredNames(
                values["required"],
                tool: tool,
                path: path
            )
            let propertySchemas = try properties.sorted { $0.key < $1.key }.map {
                name, property in
                let propertyPath = "\(path).\(name)"
                let propertySchema = try dynamicSchema(
                    property,
                    tool: tool,
                    path: propertyPath,
                    schemaName: "\(schemaName)_\(name)"
                )
                return DynamicGenerationSchema.Property(
                    name: name,
                    description: description(in: property),
                    schema: propertySchema,
                    isOptional: !required.contains(name)
                )
            }
            converted = DynamicGenerationSchema(
                name: schemaName,
                description: description(in: schema),
                properties: propertySchemas
            )

        case "array":
            guard let items = values["items"] else {
                throw error(tool, path, "Array schema requires items.")
            }
            converted = try DynamicGenerationSchema(
                arrayOf: dynamicSchema(
                    items,
                    tool: tool,
                    path: "\(path)[]",
                    schemaName: "\(schemaName)_item"
                )
            )

        case "string":
            if let choices = values["enum"] {
                guard case let .array(rawChoices) = choices else {
                    throw error(tool, path, "String enum must be an array.")
                }
                let strings = try rawChoices.map { value in
                    guard case let .string(value) = value else {
                        throw error(
                            tool,
                            path,
                            "Only string enum values are supported."
                        )
                    }
                    return value
                }
                guard !strings.isEmpty else {
                    throw error(tool, path, "String enum cannot be empty.")
                }
                converted = DynamicGenerationSchema(
                    name: schemaName,
                    description: description(in: schema),
                    anyOf: strings
                )
            } else {
                converted = DynamicGenerationSchema(type: String.self)
            }

        case "integer":
            converted = DynamicGenerationSchema(type: Int.self)
        case "number":
            converted = DynamicGenerationSchema(type: Double.self)
        case "boolean":
            converted = DynamicGenerationSchema(type: Bool.self)
        default:
            throw error(
                tool,
                path,
                "Unsupported JSON Schema type '\(schemaType.name)'."
            )
        }

        guard schemaType.allowsNull else { return converted }
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            return DynamicGenerationSchema(
                name: "\(schemaName)_nullable",
                description: description(in: schema),
                anyOf: [converted, .null]
            )
        }
        throw error(
            tool,
            path,
            "Nullable values require iOS, macOS, or visionOS 26.4 or newer."
        )
    }

    private static func schemaType(
        _ value: JSONValue?,
        tool: String,
        path: String
    ) throws -> (name: String, allowsNull: Bool) {
        switch value {
        case let .string(type):
            return (type, false)
        case let .array(types):
            let names = try types.map { value in
                guard case let .string(type) = value else {
                    throw error(
                        tool,
                        path,
                        "Schema type choices must be strings."
                    )
                }
                return type
            }
            let uniqueNames = Set(names)
            let nonNull = uniqueNames.subtracting(["null"])
            guard uniqueNames.contains("null"),
                nonNull.count == 1,
                uniqueNames.count == 2
            else {
                throw error(
                    tool,
                    path,
                    "Only a single type combined with null is supported."
                )
            }
            guard let name = nonNull.first else {
                throw error(tool, path, "Nullable schema has no value type.")
            }
            return (name, true)
        default:
            throw error(tool, path, "Schema requires a type.")
        }
    }

    private static func requiredNames(
        _ value: JSONValue?,
        tool: String,
        path: String
    ) throws -> Set<String> {
        guard let value else { return [] }
        guard case let .array(values) = value else {
            throw error(tool, path, "Required must be an array.")
        }
        return try Set(
            values.map { value in
                guard case let .string(name) = value else {
                    throw error(tool, path, "Required names must be strings.")
                }
                return name
            })
    }

    private static func description(in schema: JSONValue) -> String? {
        guard case let .object(values) = schema,
            case let .string(description)? = values["description"]
        else {
            return nil
        }
        return description
    }

    private static func error(
        _ tool: String,
        _ path: String,
        _ reason: String
    ) -> AppleFoundationModelToolBridgeError {
        .invalidSchema(tool: tool, path: path, reason: reason)
    }
}
