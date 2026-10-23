import SwiftCBOR

// CBOR helpers for the ISO 18013-5 session, on top of SwiftCBOR.
//
// Encoding (ISO 18013-5 clause 8.1):
// 1. Integers and lengths are always in the shortest form, and lengths are always definite.
// 2. Map keys are sorted bytewise. Clause 8.1 does not require sorting, but SwiftCBOR maps are
//    dictionaries, and SwiftCBOR 0.5 writes them in dictionary order, which changes from run to run.
//    So containers are written here, and only leaf values are left to SwiftCBOR.
//
// Decoding data received from a reader:
// 3. Exactly one item, and no duplicate map keys.
// 4. Bounded nesting, and no length that runs past the input.

let maxCborNestingDepth = 64
private let tagEncodedCbor: UInt64 = 24

// CBOR initial byte: top 3 bits = major type, low 5 bits = additional information (RFC 7049 2.1)
private let majorTypeShift: UInt8 = 5
private let additionalInfoMask: UInt8 = 0x1f
private let majorTypeUnsignedInteger: UInt8 = 0
private let majorTypeNegativeInteger: UInt8 = 1
private let majorTypeByteString: UInt8 = 2
private let majorTypeTextString: UInt8 = 3
private let majorTypeArray: UInt8 = 4
private let majorTypeMap: UInt8 = 5
private let majorTypeTag: UInt8 = 6
private let majorTypeSimpleOrFloat: UInt8 = 7
private let largestInlineArgument: UInt8 = 23
private let oneByteArgument: UInt8 = 24
private let twoByteArgument: UInt8 = 25
private let fourByteArgument: UInt8 = 26
private let eightByteArgument: UInt8 = 27
private let indefiniteLengthArgument: UInt8 = 31
private let breakByte: UInt8 = 0xff

/// Encodes [item] with integers and lengths in their shortest form and map keys sorted bytewise,
/// so the same item always gives the same bytes.
func encodeCbor(_ item: CBOR) -> [UInt8] {
    switch item {
    case let .array(elements):
        return cborHeader(majorType: majorTypeArray, argument: UInt64(elements.count))
            + elements.flatMap { element in encodeCbor(element) }
    case let .map(entries):
        let sortedEntries = entries
            .map { entry in (key: encodeCbor(entry.key), value: encodeCbor(entry.value)) }
            .sorted { first, second in first.key.lexicographicallyPrecedes(second.key) }
        return cborHeader(majorType: majorTypeMap, argument: UInt64(entries.count))
            + sortedEntries.flatMap { entry in entry.key + entry.value }
    case let .tagged(tag, content):
        return cborHeader(majorType: majorTypeTag, argument: tag.rawValue) + encodeCbor(content)
    default:
        // integers, strings, simple values and floats: SwiftCBOR writes these in their shortest form
        return item.encode()
    }
}

/// An initial byte plus the argument in its shortest form (RFC 7049 2.1).
private func cborHeader(majorType: UInt8, argument: UInt64) -> [UInt8] {
    let initialByte = majorType << majorTypeShift
    switch argument {
    case 0...UInt64(largestInlineArgument):
        return [initialByte | UInt8(argument)]
    case 0...0xff:
        return [initialByte | oneByteArgument, UInt8(argument)]
    case 0...0xffff:
        return [initialByte | twoByteArgument] + bigEndianBytes(argument, count: 2)
    case 0...0xffff_ffff:
        return [initialByte | fourByteArgument] + bigEndianBytes(argument, count: 4)
    default:
        return [initialByte | eightByteArgument] + bigEndianBytes(argument, count: 8)
    }
}

private func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).reversed().map { index in UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
}

/// Decodes one CBOR item received from a reader.
///
/// Note: we are lenient about *how* a reader writes something and strict about *what* it means.
/// A number in a longer form than needed, or an indefinite-length list, is accepted: its meaning
/// is clear, and anything used in cryptography is taken from the tag 24 bytes exactly as received,
/// so it cannot change a hash or a signature check. Duplicate map keys (unclear meaning) and
/// malformed or hostile input (truncated, trailing bytes, too deep, impossible lengths) are
/// rejected with CborDecodingError. Everything we send ourselves follows clause 8.1 exactly.
/// SwiftCBOR also refuses any string or count above 200,000, far above any reader request.
func decodeCbor(_ encodedCbor: [UInt8]) throws -> CBOR {
    let declaredMapEntries = try checkStructure(encodedCbor)
    let decodedItem: CBOR?
    do {
        decodedItem = try CBOR.decode(encodedCbor)
    } catch {
        throw CborDecodingError("Invalid CBOR: \(error)")
    }
    guard let item = decodedItem else { throw CborDecodingError("Expected one CBOR item, found none") }
    // SwiftCBOR keeps maps as dictionaries, so a repeated key silently replaces the earlier entry;
    // fewer entries than the input declared means some key was repeated
    guard mapEntryCount(item) == declaredMapEntries else { throw CborDecodingError("A CBOR map repeats a key") }
    return item
}

/// #6.24(bstr .cbor item): encodes [item] and wraps the bytes as a tag 24 byte string.
func tag24(_ item: CBOR) -> CBOR {
    tag24(encodedCbor: encodeCbor(item))
}

func tag24(encodedCbor: [UInt8]) -> CBOR {
    .tagged(CBOR.Tag(rawValue: tagEncodedCbor), .byteString(encodedCbor))
}

func untag24(_ item: CBOR) throws -> [UInt8] {
    guard case let .tagged(tag, .byteString(embedded)) = item, tag.rawValue == tagEncodedCbor else {
        throw CborDecodingError("Expected a tag 24 byte string")
    }
    return embedded
}

func decodeTag24(_ item: CBOR) throws -> CBOR {
    try decodeCbor(untag24(item))
}

/// Throws CborDecodingError unless [encodedCbor] is one well-formed item in the strict form
/// clause 8.1 asks of what we send: integers and lengths in their shortest form, definite lengths.
func requireStrictCbor(_ encodedCbor: [UInt8]) throws {
    try checkStructure(encodedCbor, strict: true)
}

/// How many key-value entries all the maps in [item] hold together. The decoded tree is at most
/// [maxCborNestingDepth] deep, as checkStructure has already made sure.
private func mapEntryCount(_ item: CBOR) -> UInt64 {
    switch item {
    case let .array(elements):
        return elements.reduce(0) { total, element in total + mapEntryCount(element) }
    case let .map(entries):
        return entries.reduce(UInt64(entries.count)) { total, entry in
            total + mapEntryCount(entry.key) + mapEntryCount(entry.value)
        }
    case let .tagged(_, content):
        return mapEntryCount(content)
    default:
        return 0
    }
}

/// Rejects indefinite lengths and any argument that a shorter argument size could have held.
private func checkStrictArgument(majorType: UInt8, additionalInfo: UInt8, argument: UInt64?) throws {
    guard let argument = argument else { throw CborDecodingError("Indefinite length is not allowed in strict CBOR") }
    if majorType == majorTypeSimpleOrFloat { return }
    let smallestForThisSize: UInt64
    switch additionalInfo {
    case oneByteArgument: smallestForThisSize = 24
    case twoByteArgument: smallestForThisSize = 0x100
    case fourByteArgument: smallestForThisSize = 0x1_0000
    case eightByteArgument: smallestForThisSize = 0x1_0000_0000
    default: return
    }
    if argument < smallestForThisSize {
        throw CborDecodingError("CBOR argument \(argument) is not in its shortest form")
    }
}

/// An array, map, tag or indefinite-length string that is still waiting for items.
private struct OpenContainer {
    /// Items still expected, or nil for an indefinite length, which ends with a break byte.
    var itemsStillExpected: UInt64?
    let isMap: Bool
    var itemsSeen: UInt64 = 0
}

/// Walks the item headers without recursion before SwiftCBOR decodes them, so hostile input
/// fails with CborDecodingError instead of a stack overflow or a huge allocation.
/// Checks: one complete top-level item, no trailing bytes, nesting within
/// [maxCborNestingDepth], and no length or count larger than the remaining input.
/// With [strict], also every integer, length and tag argument in its shortest form and no
/// indefinite lengths (clause 8.1 rules 1 to 3); floats and simple values are not checked.
/// Returns how many map entries the input declares, to catch repeated keys after decoding.
@discardableResult
private func checkStructure(_ encodedCbor: [UInt8], strict: Bool = false) throws -> UInt64 {
    guard !encodedCbor.isEmpty else { throw CborDecodingError("Empty CBOR input") }

    var openContainers: [OpenContainer] = []
    var readPosition = 0
    var declaredMapEntries: UInt64 = 0

    func bytesRemaining() -> UInt64 {
        UInt64(encodedCbor.count - readPosition)
    }

    /// The header's argument, or nil for an indefinite length.
    func readArgument(_ additionalInfo: UInt8) throws -> UInt64? {
        let argumentByteCount: Int
        switch additionalInfo {
        case 0...largestInlineArgument: return UInt64(additionalInfo)
        case oneByteArgument: argumentByteCount = 1
        case twoByteArgument: argumentByteCount = 2
        case fourByteArgument: argumentByteCount = 4
        case eightByteArgument: argumentByteCount = 8
        case indefiniteLengthArgument: return nil
        default: throw CborDecodingError("Reserved additional information \(additionalInfo)")
        }
        guard bytesRemaining() >= UInt64(argumentByteCount) else { throw CborDecodingError("Truncated CBOR argument") }
        var argument: UInt64 = 0
        for _ in 0..<argumentByteCount {
            argument = (argument << 8) | UInt64(encodedCbor[readPosition])
            readPosition += 1
        }
        return argument
    }

    func markItemComplete() {
        while var innermost = openContainers.popLast() {
            innermost.itemsSeen += 1
            guard let expected = innermost.itemsStillExpected else {
                openContainers.append(innermost)
                return
            }
            if expected > 1 {
                innermost.itemsStillExpected = expected - 1
                openContainers.append(innermost)
                return
            }
            // The innermost container is now complete, which completes one item of its parent
        }
    }

    func openContainer(itemCount: UInt64?, isMap: Bool) throws {
        if itemCount == 0 {
            markItemComplete()
            return
        }
        openContainers.append(OpenContainer(itemsStillExpected: itemCount, isMap: isMap))
        guard openContainers.count <= maxCborNestingDepth else {
            throw CborDecodingError("CBOR nesting deeper than \(maxCborNestingDepth)")
        }
    }

    repeat {
        guard bytesRemaining() >= 1 else { throw CborDecodingError("Truncated CBOR input") }
        let initialByte = encodedCbor[readPosition]
        readPosition += 1
        if initialByte == breakByte {
            guard let innermost = openContainers.last, innermost.itemsStillExpected == nil else {
                throw CborDecodingError("Unexpected CBOR break")
            }
            openContainers.removeLast()
            // each entry is two items: a key and a value (a key without a value fails in SwiftCBOR)
            if innermost.isMap { declaredMapEntries += innermost.itemsSeen / 2 }
            markItemComplete()
            continue
        }
        let majorType = initialByte >> majorTypeShift
        let additionalInfo = initialByte & additionalInfoMask
        let argument = try readArgument(additionalInfo)
        if strict { try checkStrictArgument(majorType: majorType, additionalInfo: additionalInfo, argument: argument) }
        if argument == nil, !(majorTypeByteString...majorTypeMap).contains(majorType) {
            throw CborDecodingError("Indefinite length not allowed for major type \(majorType)")
        }

        switch majorType {
        case majorTypeUnsignedInteger, majorTypeNegativeInteger, majorTypeSimpleOrFloat:
            markItemComplete()
        case majorTypeByteString, majorTypeTextString:
            guard let stringLength = argument else {
                try openContainer(itemCount: nil, isMap: false)
                break
            }
            guard stringLength <= bytesRemaining() else { throw CborDecodingError("CBOR string longer than the input") }
            readPosition += Int(stringLength)
            markItemComplete()
        case majorTypeArray:
            if let elementCount = argument, elementCount > bytesRemaining() {
                throw CborDecodingError("CBOR array count larger than the input")
            }
            try openContainer(itemCount: argument, isMap: false)
        case majorTypeMap:
            guard let entryCount = argument else {
                try openContainer(itemCount: nil, isMap: true)
                break
            }
            guard entryCount <= bytesRemaining() / 2 else {
                throw CborDecodingError("CBOR map count larger than the input")
            }
            declaredMapEntries += entryCount
            // each entry is two items: a key and a value
            try openContainer(itemCount: entryCount * 2, isMap: true)
        case majorTypeTag:
            try openContainer(itemCount: 1, isMap: false)
        default:
            break
        }
    } while !openContainers.isEmpty

    guard readPosition == encodedCbor.count else { throw CborDecodingError("Trailing bytes after the CBOR item") }
    return declaredMapEntries
}
