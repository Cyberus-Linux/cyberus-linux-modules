//! Helpers for creating keys and certificates.
use std::{fs, path::Path};

use anyhow::{Context, Result, ensure};
use openssl::{
    asn1::{Asn1Integer, Asn1Time},
    bn::{BigNum, MsbOption},
    hash::MessageDigest,
    pkey::{HasPublic, PKey, PKeyRef, Private},
    rsa::Rsa,
    x509::{
        X509, X509Extension, X509Name, X509NameBuilder, X509Ref, X509Req,
        extension::{AuthorityKeyIdentifier, SubjectKeyIdentifier},
    },
};

/// Should be enough for any use case. Harvest and decrypt later is not a concern, because nothing is encrypted with
/// these keys. Once attacks become relevant, systems can be migrated to stronger keys.
const RSA_KEY_BITS: u32 = 2048;

/// Who signs a certificate.
pub enum Issuer {
    /// The certificate is signed with its own key.
    SelfSigned { key: PKey<Private> },

    /// The certificate is signed by a CA.
    Ca { key: PKey<Private>, cert: X509 },
}

/// Generate a new RSA key.
pub fn generate_key() -> Result<PKey<Private>> {
    Ok(PKey::from_rsa(Rsa::generate(RSA_KEY_BITS)?)?)
}

/// Create a certificate for a given public key.
///
/// Extensions restrict what the certificate may be used for. Key identifiers are added automatically.
pub fn create_certificate(
    key: &PKeyRef<impl HasPublic>,
    common_name: &str,
    validity_days: u32,
    issuer: Issuer,
    extensions: Vec<X509Extension>,
) -> Result<X509> {
    let name = name(common_name)?;
    let serial = random_serial()?;

    let not_before = Asn1Time::days_from_now(0)?;
    let not_after = Asn1Time::days_from_now(validity_days)?;

    let mut builder = X509::builder()?;

    // X.509 v3, which is required to add extensions. Yes, 2 indicates version 3.
    builder.set_version(2)?;

    builder.set_serial_number(&serial)?;
    builder.set_subject_name(&name)?;
    builder.set_pubkey(key)?;
    builder.set_not_before(&not_before)?;
    builder.set_not_after(&not_after)?;

    let (signing_key, issuer_cert): (&PKeyRef<Private>, Option<&X509Ref>) = match &issuer {
        Issuer::SelfSigned { key: own_key } => {
            ensure!(
                own_key.public_eq(key),
                "The signing key does not match the certificate's key"
            );

            builder.set_issuer_name(&name)?;
            (own_key, None)
        }
        Issuer::Ca {
            key: ca_key,
            cert: ca_cert,
        } => {
            ensure!(
                not_after.as_ref() <= ca_cert.not_after(),
                "The certificate would be valid longer than the certificate of its issuer"
            );

            builder.set_issuer_name(ca_cert.subject_name())?;
            (ca_key, Some(ca_cert))
        }
    };

    for extension in extensions {
        builder.append_extension(extension)?;
    }

    // CA certificates must have this. It also helps verifiers to find the issuer of certificates issued by this one.
    let subject_key_id =
        SubjectKeyIdentifier::new().build(&builder.x509v3_context(issuer_cert, None))?;
    builder.append_extension(subject_key_id)?;

    // Identifies the key of the issuer. For self-signed certificates, this is the subject key identifier.
    let authority_key_id = AuthorityKeyIdentifier::new()
        .keyid(true)
        .build(&builder.x509v3_context(issuer_cert, None))?;
    builder.append_extension(authority_key_id)?;

    builder.sign(signing_key, MessageDigest::sha256())?;

    Ok(builder.build())
}

/// Create a name that only consists of a common name.
fn name(common_name: &str) -> Result<X509Name> {
    let mut name = X509NameBuilder::new()?;
    name.append_entry_by_text("CN", common_name)?;
    Ok(name.build())
}

/// Create a random serial number.
fn random_serial() -> Result<Asn1Integer> {
    // A cryptographically secure random number is okay as the serial number.
    let mut serial = BigNum::new()?;
    serial.rand(128, MsbOption::MAYBE_ZERO, false)?;
    Ok(serial.to_asn1_integer()?)
}

/// Read a certificate in PEM or DER format.
pub fn read_certificate(path: &Path) -> Result<X509> {
    let data = read_file(path)?;

    (match identify_format(&data) {
        Format::PEM => X509::from_pem(&data),
        Format::DER => X509::from_der(&data),
    })
    .with_context(|| format!("Failed to parse {} as certificate", path.display()))
}

/// Read a certificate signing request in PEM or DER format.
///
/// HSMs often hand out CSRs in DER format, while OpenSSL defaults to PEM.
pub fn read_csr(path: &Path) -> Result<X509Req> {
    let data = read_file(path)?;

    (match identify_format(&data) {
        Format::PEM => X509Req::from_pem(&data),
        Format::DER => X509Req::from_der(&data),
    })
    .with_context(|| format!("Failed to parse {} as CSR", path.display()))
}

/// Read a private key in PEM format and its certificate in PEM or DER format, and check that they belong together.
pub fn read_key_pair(key_path: &Path, cert_path: &Path) -> Result<(PKey<Private>, X509)> {
    let key = PKey::private_key_from_pem(&read_file(key_path)?)
        .with_context(|| format!("Failed to parse {} as private key", key_path.display()))?;
    let cert = read_certificate(cert_path)?;

    ensure!(
        cert.public_key()?.public_eq(&key),
        "{} does not belong to {}",
        key_path.display(),
        cert_path.display()
    );

    Ok((key, cert))
}

fn read_file(path: &Path) -> Result<Vec<u8>> {
    fs::read(path).with_context(|| format!("Failed to read {}", path.display()))
}

#[allow(clippy::upper_case_acronyms)]
enum Format {
    /// "Privacy Enhanced Mail"
    PEM,
    /// "Distinguished Encoding Rules"
    DER,
}

/// A quick and dirty way to infer the format of a certificate or CSR.
fn identify_format(data: &[u8]) -> Format {
    if data.starts_with(b"-----BEGIN") {
        Format::PEM
    } else {
        Format::DER
    }
}
