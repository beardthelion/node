//! Encrypt-then-pin for withheld blobs (Option B1). Each withheld blob is sealed
//! to its recipient DIDs and the envelope pinned to IPFS, recorded in
//! `encrypted_blobs`. Best-effort per blob: a failure is logged and skipped,
//! never pinned in plaintext.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::str::FromStr;

use ed25519_dalek::VerifyingKey;
use gitlawb_core::did::Did;
use gitlawb_core::encrypt::seal_blob;

use crate::db::Db;

use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// Opaque, node-keyed fingerprint of a blob's recipient set. Stored in place of
/// the cleartext DID list so a DB compromise cannot reveal the reader set; used
/// only to detect a recipient-set change so an unchanged blob is not re-sealed.
/// Order-insensitive (the input `BTreeSet` is already sorted).
pub fn recipients_tag(node_seed: &[u8; 32], dids: &BTreeSet<String>) -> String {
    let mut mac = HmacSha256::new_from_slice(node_seed).expect("HMAC accepts any key length");
    mac.update(b"gitlawb/recipients-tag/v1");
    for did in dids {
        mac.update(b"\n");
        mac.update(did.as_bytes());
    }
    hex::encode(mac.finalize().into_bytes())
}

/// Resolve a DID string to its Ed25519 verifying key, or None if it carries no
/// inline key (e.g. did:web / did:gitlawb).
fn did_to_key(did: &str) -> Option<VerifyingKey> {
    Did::from_str(did).ok()?.to_verifying_key().ok()
}

/// Resolve every recipient DID to its verifying key. Fails closed: returns the
/// keys only if *all* DIDs resolve, otherwise `Err(n)` where `n` is the count
/// that could not be resolved. A blob must never be sealed to fewer readers than
/// its rule grants, so a partial resolution is an error, not a partial key set.
/// Returns the count, never the DID strings, so recipient identities stay out of
/// logs (consistent with at-rest recipient blinding).
fn resolve_recipient_keys(dids: &BTreeSet<String>) -> Result<Vec<VerifyingKey>, usize> {
    let mut keys = Vec::with_capacity(dids.len());
    let mut unresolved = 0usize;
    for d in dids {
        match did_to_key(d) {
            Some(k) => keys.push(k),
            None => unresolved += 1,
        }
    }
    if unresolved == 0 {
        Ok(keys)
    } else {
        Err(unresolved)
    }
}

/// Encrypt and pin every withheld blob. `recipients` maps blob oid -> DID set;
/// `node_seed` keys the opaque recipients tag. Returns `(oid, cid)` for each blob
/// actually sealed and recorded this call (the per-push delta), used by Option B3
/// to anchor a manifest. Recipient identities are never stored or returned.
pub async fn encrypt_and_pin(
    ipfs_api: &str,
    repo_path: &Path,
    db: &Db,
    repo_id: &str,
    node_seed: &[u8; 32],
    recipients: &HashMap<String, BTreeSet<String>>,
) -> Vec<(String, String)> {
    let mut sealed = Vec::new();
    for (oid, dids) in recipients {
        // Skip only if an existing envelope already covers exactly these
        // recipients. If the recipient set changed (e.g. a reader was added to
        // the rule), re-seal so the new reader can recover the blob. Reader
        // removal is not retroactive: the old envelope is already public. The
        // comparison is on the opaque node-keyed tag, never the DID list.
        let tag = recipients_tag(node_seed, dids);
        match db.encrypted_blob_recipients_tag(repo_id, oid).await {
            Ok(Some(stored_tag)) if stored_tag == tag => continue,
            Ok(_) => {}
            Err(e) => {
                // A DB read failure is not a cache miss: re-sealing here would do
                // an avoidable IPFS write during a partial outage. Skip and retry
                // on the next push.
                tracing::warn!(oid = %oid, err = %e, "recipients_tag lookup failed; skipping reseal");
                continue;
            }
        }
        let keys = match resolve_recipient_keys(dids) {
            Ok(keys) if !keys.is_empty() => keys,
            Ok(_) => {
                tracing::warn!(oid = %oid, "no recipient DIDs to seal to; skipping");
                continue;
            }
            Err(unresolved) => {
                tracing::warn!(
                    oid = %oid,
                    unresolved,
                    total = dids.len(),
                    "unresolvable recipient DIDs; skipping to avoid sealing to a partial set"
                );
                continue;
            }
        };
        let data = match crate::git::store::read_object(repo_path, oid) {
            Ok(Some((_t, bytes))) => bytes,
            Ok(None) => {
                tracing::debug!(oid = %oid, "withheld blob not found in store; skipping");
                continue;
            }
            Err(e) => {
                tracing::warn!(oid = %oid, err = %e, "read_object failed; skipping");
                continue;
            }
        };
        let envelope = match seal_blob(&data, &keys) {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!(oid = %oid, err = %e, "seal_blob failed; skipping");
                continue;
            }
        };
        let cid = match crate::ipfs_pin::pin_git_object(ipfs_api, oid, &envelope).await {
            Ok(c) if !c.is_empty() => c,
            Ok(_) => {
                tracing::warn!(oid = %oid, "pin_git_object returned empty cid; skipping");
                continue;
            }
            Err(e) => {
                tracing::warn!(oid = %oid, err = %e, "pin_git_object failed; skipping");
                continue;
            }
        };
        if let Err(e) = db.record_encrypted_blob(repo_id, oid, &cid, &tag).await {
            tracing::warn!(oid = %oid, err = %e, "record_encrypted_blob failed");
            continue;
        }
        sealed.push((oid.clone(), cid.clone()));
    }
    sealed
}

#[cfg(test)]
mod tests {
    use super::{recipients_tag, resolve_recipient_keys};
    use std::collections::BTreeSet;

    fn set(dids: &[&str]) -> BTreeSet<String> {
        dids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn tag_is_order_insensitive() {
        let seed = [7u8; 32];
        let a = recipients_tag(&seed, &set(&["did:key:zA", "did:key:zB"]));
        let b = recipients_tag(&seed, &set(&["did:key:zB", "did:key:zA"]));
        assert_eq!(a, b);
    }

    #[test]
    fn tag_differs_for_different_sets() {
        let seed = [7u8; 32];
        let a = recipients_tag(&seed, &set(&["did:key:zA"]));
        let b = recipients_tag(&seed, &set(&["did:key:zA", "did:key:zB"]));
        assert_ne!(a, b);
    }

    #[test]
    fn tag_is_keyed_by_node_seed() {
        let dids = set(&["did:key:zA", "did:key:zB"]);
        let a = recipients_tag(&[1u8; 32], &dids);
        let b = recipients_tag(&[2u8; 32], &dids);
        assert_ne!(
            a, b,
            "tag must depend on the node seed, not be a plain hash"
        );
    }

    use gitlawb_core::identity::Keypair;

    /// A freshly generated, locally resolvable `did:key` string.
    fn real_did_key() -> String {
        Keypair::generate().did().to_string()
    }

    #[test]
    fn resolver_returns_all_keys_when_all_resolve() {
        let a = real_did_key();
        let b = real_did_key();
        let dids = set(&[&a, &b]);
        let keys = resolve_recipient_keys(&dids).expect("generated did:keys should resolve");
        assert_eq!(keys.len(), 2);
    }

    #[test]
    fn resolver_fails_closed_when_one_did_unresolvable() {
        // One good did:key, one did:web that cannot be keyed locally.
        let a = real_did_key();
        let dids = set(&[&a, "did:web:example.com"]);
        let err = resolve_recipient_keys(&dids)
            .expect_err("a single unresolvable DID must fail the whole set");
        assert_eq!(err, 1, "should report exactly one unresolved DID");
    }

    #[test]
    fn resolver_reports_count_when_all_unresolvable() {
        let dids = set(&["did:web:a.example", "did:gitlawb:zXYZ"]);
        let err = resolve_recipient_keys(&dids).expect_err("none resolvable");
        assert_eq!(err, 2);
    }

    #[test]
    fn resolver_ok_empty_for_empty_input() {
        let dids: BTreeSet<String> = BTreeSet::new();
        let keys = resolve_recipient_keys(&dids).expect("empty set resolves to empty keys");
        assert!(keys.is_empty());
    }
}
