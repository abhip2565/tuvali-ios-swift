import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// The certificate fields reader authentication reads itself, from DER (RFC 5280, ITU-T X.690).
final class ReaderCertificateTests: XCTestCase {

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    /// The reader's own certificate: the first in the x5chain of the valid test readerAuth.
    private func readerLeaf() throws -> [UInt8] {
        let sign1 = try decodeCbor(SessionTestVectors.bytes("readerAuth.valid"))
        let unprotected = try sign1.items[1].asMap("unprotected")
        return try XCTUnwrap(unprotected[33]?.bytes)
    }

    func testInitReadsTheCommonNameAndValidityOfTheTestRoot() throws {
        let certificate = try ReaderCertificate(der: SessionTestVectors.bytes("readerAuth.rootCertificate"))

        XCTAssertEqual(certificate.commonName, "Tuvali Test Reader CA")
        XCTAssertEqual(certificate.notBefore, try date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(certificate.notAfter, try date("2036-01-01T00:00:00Z"))
    }

    func testInitReadsAP256KeyAsItsUncompressedPoint() throws {
        let certificate = try ReaderCertificate(der: SessionTestVectors.bytes("readerAuth.rootCertificate"))

        guard case let .ec(curve, point) = certificate.publicKey else { return XCTFail("\(certificate.publicKey)") }
        XCTAssertEqual(curve, .p256)
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(point.first, 0x04)
    }

    func testInitReadsKeyUsageWithoutDigitalSignatureAndNoExtendedKeyUsageForTheCa() throws {
        // the test root allows certificate and CRL signing only
        let certificate = try ReaderCertificate(der: SessionTestVectors.bytes("readerAuth.rootCertificate"))

        XCTAssertEqual(certificate.allowsDigitalSignature, false)
        XCTAssertNil(certificate.extendedKeyUsages)
    }

    func testInitReadsDigitalSignatureAndTheMdocReaderAuthenticationPurposeForTheReader() throws {
        let certificate = try ReaderCertificate(der: readerLeaf())

        XCTAssertEqual(certificate.commonName, "Tuvali Test Reader")
        XCTAssertEqual(certificate.allowsDigitalSignature, true)
        XCTAssertEqual(certificate.extendedKeyUsages, ["1.0.18013.5.1.6"])
    }

    func testInitThrowsCertificateParsingErrorForBytesThatAreNotACertificate() {
        XCTAssertThrowsError(try ReaderCertificate(der: [0x30, 0x03, 0x02, 0x01, 0x01]), ofType: CertificateParsingError.self)
    }

    func testInitThrowsCertificateParsingErrorForACertificateWithTrailingBytes() throws {
        let withTrailingByte = SessionTestVectors.bytes("readerAuth.rootCertificate") + [0x00]

        XCTAssertThrowsError(try ReaderCertificate(der: withTrailingByte), ofType: CertificateParsingError.self)
    }

    // MARK: the DER reader

    func testObjectIdentifierReadsMultiByteArcs() throws {
        // 1.0.18013.5.1.6, the mdoc reader authentication purpose: 18013 takes three bytes
        let element = try DerReader.single("060728818c5d050106".hexToBytes())

        XCTAssertEqual(try element.objectIdentifier(), "1.0.18013.5.1.6")
    }

    func testObjectIdentifierReadsASecondArcAbove39UnderTheFirstArc2() throws {
        // 2.999.3: the first two arcs together are 80 + 999, written in two bytes
        let element = try DerReader.single("0603883703".hexToBytes())

        XCTAssertEqual(try element.objectIdentifier(), "2.999.3")
    }

    func testObjectIdentifierThrowsWhenTheLastArcIsCutOff() throws {
        // the last byte still has its continuation bit set
        let element = try DerReader.single("06022a86".hexToBytes())

        XCTAssertThrowsError(try element.objectIdentifier(), ofType: CertificateParsingError.self)
    }

    func testReadThrowsForAnIndefiniteLength() {
        // DER allows only definite lengths
        var reader = DerReader("30800000".hexToBytes())

        XCTAssertThrowsError(try reader.read(), ofType: CertificateParsingError.self)
    }

    func testReadThrowsWhenTheLengthRunsPastTheInput() {
        var reader = DerReader("30050101".hexToBytes())

        XCTAssertThrowsError(try reader.read(), ofType: CertificateParsingError.self)
    }

    func testReadReadsALongFormLength() throws {
        // 0x81 0x80: the length 128 in one further byte
        var reader = DerReader([0x04, 0x81, 0x80] + [UInt8](repeating: 7, count: 128))

        let element = try reader.read()

        XCTAssertEqual(element.content.count, 128)
        XCTAssertTrue(reader.isAtEnd)
    }
    func testRejectsNonMinimalDerLengthsAndOidArcs() {
        for bytes: [UInt8] in [[0x04, 0x81, 1, 0], [0x04, 0x82, 0, 0x80] + Array(repeating: 0, count: 128)] {
            XCTAssertThrowsError(try DerReader.single(bytes), ofType: CertificateParsingError.self)
        }
        XCTAssertThrowsError(try DerReader.single([0x06, 2, 0x80, 0x2a]).objectIdentifier(), ofType: CertificateParsingError.self)
    }

    func testRejectsImpossibleCertificateCalendarDate() throws {
        var bytes = try readerLeaf()
        let original = Array("260101000000Z".utf8)
        let start = try XCTUnwrap(bytes.indices.first { index in
            index + original.count <= bytes.count && Array(bytes[index..<(index + original.count)]) == original
        })
        bytes.replaceSubrange(start..<(start + original.count), with: Array("260231000000Z".utf8))
        XCTAssertThrowsError(try ReaderCertificate(der: bytes), ofType: CertificateParsingError.self)
    }

    func testRejectsDuplicateCertificateExtensions() throws {
        let certificate = try DerReader.single(readerLeaf())
        var outer = try certificate.children()
        var tbs = try outer[0].children()
        let index = try XCTUnwrap(tbs.firstIndex { $0.tag == 0xa3 })
        let wrapper = try tbs[index].children()
        var extensions = try wrapper[0].children()
        extensions.append(try XCTUnwrap(extensions.first))
        tbs[index] = DerElement(tag: 0xa3, content: der(DerElement(tag: derTagSequence, content: extensions.flatMap(der))))
        outer[0] = DerElement(tag: derTagSequence, content: tbs.flatMap(der))
        let duplicate = der(DerElement(tag: derTagSequence, content: outer.flatMap(der)))
        XCTAssertThrowsError(try ReaderCertificate(der: duplicate), ofType: CertificateParsingError.self)
    }

    private func der(_ element: DerElement) -> [UInt8] {
        let count = element.content.count
        let length: [UInt8]
        if count < 128 { length = [UInt8(count)] }
        else if count <= 255 { length = [0x81, UInt8(count)] }
        else { length = [0x82, UInt8(count >> 8), UInt8(count & 255)] }
        return [element.tag] + length + element.content
    }

}
