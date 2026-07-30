#!/usr/bin/env python3

"""Build and compare a reviewable compatibility manifest from FileDescriptorSet."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import stat
import sys
from typing import Any


MAX_DESCRIPTOR_BYTES = 16 * 1024 * 1024
MAX_BASELINE_BYTES = 16 * 1024 * 1024
MANIFEST_SCHEMA_VERSION = 2
ADDITIVE_MAP_KEYS = frozenset(
    {
        "dependencies",
        "enums",
        "fields",
        "files",
        "messages",
        "methods",
        "services",
        "values",
    }
)

FIELD_LABELS = {
    1: "optional",
    2: "required",
    3: "repeated",
}
FIELD_TYPES = {
    1: "double",
    2: "float",
    3: "int64",
    4: "uint64",
    5: "int32",
    6: "fixed64",
    7: "fixed32",
    8: "bool",
    9: "string",
    10: "group",
    11: "message",
    12: "bytes",
    13: "uint32",
    14: "enum",
    15: "sfixed32",
    16: "sfixed64",
    17: "sint32",
    18: "sint64",
}


class CompatibilityInputError(RuntimeError):
    """The descriptor or baseline cannot be trusted enough to compare."""


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(data) and shift < 70:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise CompatibilityInputError("invalid or truncated descriptor varint")


def decode_fields(data: bytes) -> dict[int, list[tuple[int, int | bytes]]]:
    fields: dict[int, list[tuple[int, int | bytes]]] = {}
    offset = 0
    while offset < len(data):
        key, offset = read_varint(data, offset)
        number = key >> 3
        wire_type = key & 0x07
        if number == 0:
            raise CompatibilityInputError("descriptor contains field number zero")
        if wire_type == 0:
            value, offset = read_varint(data, offset)
        elif wire_type == 1:
            end = offset + 8
            if end > len(data):
                raise CompatibilityInputError("truncated fixed64 descriptor field")
            value = data[offset:end]
            offset = end
        elif wire_type == 2:
            length, offset = read_varint(data, offset)
            end = offset + length
            if end > len(data):
                raise CompatibilityInputError("truncated length-delimited descriptor field")
            value = data[offset:end]
            offset = end
        elif wire_type == 5:
            end = offset + 4
            if end > len(data):
                raise CompatibilityInputError("truncated fixed32 descriptor field")
            value = data[offset:end]
            offset = end
        else:
            raise CompatibilityInputError(
                f"unsupported descriptor wire type {wire_type}"
            )
        fields.setdefault(number, []).append((wire_type, value))
    return fields


def repeated_bytes(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
) -> list[bytes]:
    values: list[bytes] = []
    for wire_type, value in fields.get(number, []):
        if wire_type != 2 or not isinstance(value, bytes):
            raise CompatibilityInputError(
                f"descriptor field {number} has an unexpected wire type"
            )
        values.append(value)
    return values


def repeated_varints(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
) -> list[int]:
    values: list[int] = []
    for wire_type, value in fields.get(number, []):
        if wire_type == 0 and isinstance(value, int):
            values.append(value)
            continue
        if wire_type == 2 and isinstance(value, bytes):
            offset = 0
            while offset < len(value):
                item, offset = read_varint(value, offset)
                values.append(item)
            continue
        raise CompatibilityInputError(
            f"descriptor field {number} has an unexpected wire type"
        )
    return values


def repeated_text(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
) -> list[str]:
    values: list[str] = []
    for value in repeated_bytes(fields, number):
        try:
            values.append(value.decode("utf-8"))
        except UnicodeDecodeError as error:
            raise CompatibilityInputError(
                f"descriptor field {number} is not valid UTF-8"
            ) from error
    return values


def optional_bytes(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
) -> bytes | None:
    values = repeated_bytes(fields, number)
    if len(values) > 1:
        raise CompatibilityInputError(
            f"singular descriptor field {number} is repeated"
        )
    return values[0] if values else None


def optional_text(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
    default: str | None = None,
) -> str | None:
    value = optional_bytes(fields, number)
    if value is None:
        return default
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CompatibilityInputError(
            f"descriptor field {number} is not valid UTF-8"
        ) from error


def optional_varint(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
    default: int | None = None,
) -> int | None:
    values = fields.get(number, [])
    if len(values) > 1:
        raise CompatibilityInputError(
            f"singular descriptor field {number} is repeated"
        )
    if not values:
        return default
    wire_type, value = values[0]
    if wire_type != 0 or not isinstance(value, int):
        raise CompatibilityInputError(
            f"descriptor field {number} has an unexpected wire type"
        )
    return value


def required_text(
    fields: dict[int, list[tuple[int, int | bytes]]],
    number: int,
    label: str,
) -> str:
    value = optional_text(fields, number)
    if not value:
        raise CompatibilityInputError(f"descriptor {label} is missing")
    return value


def signed_int32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value >= 0x80000000 else value


def qualified_name(parent: str, name: str) -> str:
    return f"{parent}.{name}" if parent else name


def selected_options(
    data: bytes | None,
    definitions: dict[int, tuple[str, str]],
) -> dict[str, Any]:
    if data is None:
        return {}
    fields = decode_fields(data)
    result: dict[str, Any] = {}
    for number, (name, value_type) in definitions.items():
        if value_type == "text":
            value = optional_text(fields, number)
        elif value_type == "bool":
            raw_value = optional_varint(fields, number)
            value = None if raw_value is None else bool(raw_value)
        else:
            value = optional_varint(fields, number)
        if value is not None:
            result[name] = value
    return result


def parse_field(data: bytes, oneof_names: list[str]) -> dict[str, Any]:
    fields = decode_fields(data)
    number = optional_varint(fields, 3)
    label_number = optional_varint(fields, 4)
    type_number = optional_varint(fields, 5)
    if number is None or number <= 0:
        raise CompatibilityInputError("descriptor field has an invalid number")
    if label_number not in FIELD_LABELS or type_number not in FIELD_TYPES:
        raise CompatibilityInputError("descriptor field has an invalid label or type")
    oneof_index = optional_varint(fields, 9)
    if oneof_index is not None and oneof_index >= len(oneof_names):
        raise CompatibilityInputError("descriptor field has an invalid oneof index")
    return {
        "name": required_text(fields, 1, "field name"),
        "number": number,
        "label": FIELD_LABELS[label_number],
        "type": FIELD_TYPES[type_number],
        "json_name": optional_text(fields, 10, ""),
        "type_name": optional_text(fields, 6, ""),
        "extendee": optional_text(fields, 2, ""),
        "default_value": optional_text(fields, 7),
        "oneof": oneof_names[oneof_index] if oneof_index is not None else None,
        "proto3_optional": bool(optional_varint(fields, 17, 0)),
        "options": selected_options(
            optional_bytes(fields, 8),
            {
                1: ("ctype", "int"),
                2: ("packed", "bool"),
                3: ("jstype", "int"),
                5: ("lazy", "bool"),
                10: ("weak", "bool"),
            },
        ),
    }


def parse_range(data: bytes, end_exclusive: bool) -> list[int]:
    fields = decode_fields(data)
    start = optional_varint(fields, 1)
    end = optional_varint(fields, 2)
    if start is None or end is None or end < start:
        raise CompatibilityInputError("descriptor contains an invalid reserved range")
    return [signed_int32(start), signed_int32(end), int(end_exclusive)]


def parse_enum(
    data: bytes,
    parent: str,
    file_name: str,
    manifest: dict[str, Any],
) -> None:
    fields = decode_fields(data)
    name = required_text(fields, 1, "enum name")
    full_name = qualified_name(parent, name)
    values: dict[str, int] = {}
    for value_data in repeated_bytes(fields, 2):
        value_fields = decode_fields(value_data)
        value_name = required_text(value_fields, 1, "enum value name")
        raw_number = optional_varint(value_fields, 2)
        if raw_number is None or value_name in values:
            raise CompatibilityInputError(f"enum {full_name} has an invalid value")
        values[value_name] = signed_int32(raw_number)
    reserved_ranges = sorted(
        parse_range(item, end_exclusive=False)
        for item in repeated_bytes(fields, 4)
    )
    reserved_names = sorted(repeated_text(fields, 5))
    options = selected_options(
        optional_bytes(fields, 3),
        {2: ("allow_alias", "bool")},
    )
    manifest["enums"][full_name] = {
        "file": file_name,
        "values": values,
        "reserved_ranges": reserved_ranges,
        "reserved_names": reserved_names,
        "options": options,
    }


def parse_message(
    data: bytes,
    parent: str,
    file_name: str,
    manifest: dict[str, Any],
) -> None:
    fields = decode_fields(data)
    name = required_text(fields, 1, "message name")
    full_name = qualified_name(parent, name)
    if repeated_bytes(fields, 5) or repeated_bytes(fields, 6):
        raise CompatibilityInputError(
            f"message {full_name} uses protobuf extensions, which this "
            "compatibility manifest does not yet model"
        )
    oneof_names = [
        required_text(decode_fields(item), 1, "oneof name")
        for item in repeated_bytes(fields, 8)
    ]
    parsed_fields: dict[str, Any] = {}
    for field_data in repeated_bytes(fields, 2):
        parsed = parse_field(field_data, oneof_names)
        number_key = str(parsed.pop("number"))
        if number_key in parsed_fields:
            raise CompatibilityInputError(
                f"message {full_name} repeats field number {number_key}"
            )
        parsed_fields[number_key] = parsed
    reserved_ranges = sorted(
        parse_range(item, end_exclusive=True)
        for item in repeated_bytes(fields, 9)
    )
    reserved_names = sorted(repeated_text(fields, 10))
    options = selected_options(
        optional_bytes(fields, 7),
        {7: ("map_entry", "bool")},
    )
    manifest["messages"][full_name] = {
        "file": file_name,
        "fields": parsed_fields,
        "reserved_ranges": reserved_ranges,
        "reserved_names": reserved_names,
        "options": options,
    }
    for nested in repeated_bytes(fields, 3):
        parse_message(nested, full_name, file_name, manifest)
    for enum_data in repeated_bytes(fields, 4):
        parse_enum(enum_data, full_name, file_name, manifest)


def parse_service(
    data: bytes,
    parent: str,
    file_name: str,
    manifest: dict[str, Any],
) -> None:
    fields = decode_fields(data)
    name = required_text(fields, 1, "service name")
    full_name = qualified_name(parent, name)
    methods: dict[str, Any] = {}
    for method_data in repeated_bytes(fields, 2):
        method_fields = decode_fields(method_data)
        method_name = required_text(method_fields, 1, "method name")
        methods[method_name] = {
            "input_type": required_text(method_fields, 2, "method input type"),
            "output_type": required_text(method_fields, 3, "method output type"),
            "client_streaming": bool(optional_varint(method_fields, 5, 0)),
            "server_streaming": bool(optional_varint(method_fields, 6, 0)),
        }
    manifest["services"][full_name] = {"file": file_name, "methods": methods}


def descriptor_manifest(data: bytes) -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "files": {},
        "messages": {},
        "enums": {},
        "services": {},
    }
    root_fields = decode_fields(data)
    file_descriptors = repeated_bytes(root_fields, 1)
    if not file_descriptors:
        raise CompatibilityInputError("descriptor set contains no files")
    for file_data in file_descriptors:
        fields = decode_fields(file_data)
        file_name = required_text(fields, 1, "file name")
        package = optional_text(fields, 2, "") or ""
        if repeated_bytes(fields, 7):
            raise CompatibilityInputError(
                f"file {file_name} uses protobuf extensions, which this "
                "compatibility manifest does not yet model"
            )
        dependencies = repeated_text(fields, 3)
        if len(dependencies) != len(set(dependencies)):
            raise CompatibilityInputError(
                f"file {file_name} repeats a protobuf dependency"
            )
        public_indices = set(repeated_varints(fields, 10))
        weak_indices = set(repeated_varints(fields, 11))
        if public_indices & weak_indices or any(
            index >= len(dependencies) for index in public_indices | weak_indices
        ):
            raise CompatibilityInputError(
                f"file {file_name} has an invalid dependency classification"
            )
        dependency_modes = {
            dependency: (
                "public"
                if index in public_indices
                else "weak"
                if index in weak_indices
                else "normal"
            )
            for index, dependency in enumerate(dependencies)
        }
        if file_name in manifest["files"]:
            raise CompatibilityInputError(f"descriptor repeats file {file_name}")
        file_manifest: dict[str, Any] = {
            "package": package,
            "syntax": optional_text(fields, 12, "proto2"),
            "dependencies": dependency_modes,
            "options": selected_options(
                optional_bytes(fields, 8),
                {
                    1: ("java_package", "text"),
                    8: ("java_outer_classname", "text"),
                    9: ("optimize_for", "int"),
                    10: ("java_multiple_files", "bool"),
                    11: ("go_package", "text"),
                    31: ("cc_enable_arenas", "bool"),
                    36: ("objc_class_prefix", "text"),
                    37: ("csharp_namespace", "text"),
                    39: ("swift_prefix", "text"),
                },
            ),
        }
        if optional_varint(fields, 14) is not None:
            raise CompatibilityInputError(
                f"file {file_name} uses protobuf editions, which this "
                "compatibility manifest does not yet model"
            )
        manifest["files"][file_name] = file_manifest
        for message_data in repeated_bytes(fields, 4):
            parse_message(message_data, package, file_name, manifest)
        for enum_data in repeated_bytes(fields, 5):
            parse_enum(enum_data, package, file_name, manifest)
        for service_data in repeated_bytes(fields, 6):
            parse_service(service_data, package, file_name, manifest)
    for file_name, file_manifest in manifest["files"].items():
        for dependency in file_manifest["dependencies"]:
            if dependency not in manifest["files"]:
                raise CompatibilityInputError(
                    f"file {file_name} dependency {dependency} is missing from "
                    "the descriptor set; compile with --include_imports"
                )
    return manifest


def require_compatible_subset(
    expected: Any,
    current: Any,
    path: tuple[str, ...],
    errors: list[str],
) -> None:
    location = ".".join(path) or "<root>"
    if isinstance(expected, dict):
        if not isinstance(current, dict):
            errors.append(f"{location} changed shape")
            return
        for key, value in expected.items():
            child_path = (*path, str(key))
            if key not in current:
                errors.append(f"{'.'.join(child_path)} was removed")
            else:
                require_compatible_subset(value, current[key], child_path, errors)
        if path and path[-1] == "fields":
            for key in current.keys() - expected.keys():
                field = current[key]
                if isinstance(field, dict) and field.get("label") == "required":
                    errors.append(
                        f"{'.'.join((*path, str(key)))} added a required field"
                    )
        if not path or path[-1] not in ADDITIVE_MAP_KEYS:
            for key in current.keys() - expected.keys():
                errors.append(
                    f"{'.'.join((*path, str(key)))} added an incompatible property"
                )
        return
    if isinstance(expected, list):
        if not isinstance(current, list):
            errors.append(f"{location} changed shape")
            return
        for value in expected:
            if value not in current:
                errors.append(f"{location} no longer contains {value!r}")
        return
    if expected != current:
        errors.append(f"{location} changed from {expected!r} to {current!r}")


def describe_os_error(error: OSError) -> str:
    return f"[Errno {error.errno}] {error.strerror or 'operating-system error'}"


def read_regular_file(path: pathlib.Path, maximum: int, label: str) -> bytes:
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise CompatibilityInputError(f"{label} is not a single-link regular file")
        if before.st_size <= 0 or before.st_size > maximum:
            raise CompatibilityInputError(f"{label} size is outside the accepted bounds")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = None
            value = stream.read(maximum + 1)
            after = os.fstat(stream.fileno())
        if (
            len(value) != before.st_size
            or after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise CompatibilityInputError(f"{label} changed while it was read")
        return value
    except OSError as error:
        raise CompatibilityInputError(
            f"cannot read {label}: {describe_os_error(error)}"
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def read_descriptor(path: pathlib.Path) -> bytes:
    return read_regular_file(path, MAX_DESCRIPTOR_BYTES, "descriptor")


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CompatibilityInputError(
                f"compatibility baseline repeats JSON key {key!r}"
            )
        result[key] = value
    return result


def read_baseline(path: pathlib.Path) -> dict[str, Any]:
    try:
        raw_value = read_regular_file(path, MAX_BASELINE_BYTES, "compatibility baseline")
        value = json.loads(
            raw_value.decode("utf-8"),
            object_pairs_hook=unique_json_object,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CompatibilityInputError(f"cannot read compatibility baseline: {error}") from error
    if not isinstance(value, dict) or value.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise CompatibilityInputError("unsupported compatibility baseline schema")
    for required in ("files", "messages", "enums", "services"):
        if not isinstance(value.get(required), dict):
            raise CompatibilityInputError(
                f"compatibility baseline is missing {required}"
            )
    return value


def write_baseline(path: pathlib.Path, manifest: dict[str, Any]) -> None:
    descriptor: int | None = None
    payload = (
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = None
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except FileExistsError as error:
        raise CompatibilityInputError(
            "refusing to replace an existing baseline"
        ) from error
    except OSError as error:
        raise CompatibilityInputError(
            f"cannot write compatibility baseline: {describe_os_error(error)}"
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--descriptor", required=True, type=pathlib.Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--baseline", type=pathlib.Path)
    mode.add_argument("--write-baseline", type=pathlib.Path)
    parser.add_argument("--previous-baseline", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        manifest = descriptor_manifest(read_descriptor(arguments.descriptor))
        if arguments.write_baseline is not None:
            if arguments.previous_baseline is not None:
                raise CompatibilityInputError(
                    "--previous-baseline requires comparison mode"
                )
            write_baseline(arguments.write_baseline, manifest)
            print("Proto compatibility baseline written.")
            print("中文：Protobuf 兼容性基线已写入调用方指定的新文件。")
            return 0
        baseline = read_baseline(arguments.baseline)
        errors: list[str] = []
        require_compatible_subset(baseline, manifest, (), errors)
        if baseline != manifest:
            errors.append(
                "compatibility baseline is stale; generate and review an exact candidate"
            )
        if arguments.previous_baseline is not None:
            previous_baseline = read_baseline(arguments.previous_baseline)
            require_compatible_subset(
                previous_baseline,
                baseline,
                (),
                errors,
            )
        if errors:
            print("Proto compatibility check failed:", file=sys.stderr)
            for error in errors[:50]:
                print(f"- {error}", file=sys.stderr)
            if len(errors) > 50:
                print(f"- and {len(errors) - 50} more", file=sys.stderr)
            return 1
        print("Proto compatibility check passed against the reviewed v1 baseline.")
        print("中文：Protobuf 兼容性检查通过，当前 schema 未破坏已审核的 v1 基线。")
        return 0
    except CompatibilityInputError as error:
        print(f"Proto compatibility input error: {error}", file=sys.stderr)
        return 2
    except RecursionError:
        print(
            "Proto compatibility input error: descriptor or baseline nesting is too deep",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
