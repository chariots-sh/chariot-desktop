import Foundation
import CryptoKit
import CloudKit
import AgentLinkKit
import AgentLinkCloudKit

/// CloudKit transport mode for the hub (design §4.6, §13.9). When enabled, the
/// QR payload advertises the CloudKit container and phone-bound envelopes go to
/// the private-database mailbox instead of the localhost stand-in. The Mac
/// polls its side of the mailbox; pushes are an accelerator, not a dependency.
extension ChariotHub {

    public func enableCloudKit(containerID: String) async throws {
        do {
            let mailbox = CloudKitMailbox(containerIdentifier: containerID)
            try await mailbox.prepare()
            setCloudKit(mailbox: mailbox, containerID: containerID)

            // CKSyncEngine (design §13.9): daemon-channel change pushes +
            // server change tokens + system scheduling. Envelope and pairing
            // record changes stream in without app-delegate APNs.
            let inbox = CloudKitSyncInbox(mailbox: mailbox, stateDirectory: paths.identityDirectory)
            inbox.onEnvelope = { [weak self] envelope in
                guard let self, envelope.recipientDeviceID == self.identity.deviceID else { return }
                self.processInboundEnvelope(envelope)
                Task { try? await mailbox.acknowledge(messageIDs: [envelope.messageID]) }
            }
            inbox.onPairingRecordChanged = { [weak self] rendezvousID in
                guard let self else { return }
                Task { await self.checkCloudPairingSession(rendezvousID) }
            }
            inbox.onLog = { [weak self] message in self?.event(message) }
            inbox.start()
            inbox.fetchNow()
            syncInbox = inbox
            // Push delivery on macOS proved unreliable (deferred for minutes),
            // so reconcile on a steady cadence. With CKSyncEngine these are
            // change-token delta fetches — near-free when nothing changed.
            cloudReconcileTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    self?.syncInbox?.fetchNow()
                }
            }
            event("CloudKit mailbox ready: \(containerID)")
        } catch {
            event("cloudkit enable failed: \(error)")
            throw error
        }
    }

    /// Wake nudge (app activation, post-login refresh): ask the engine to fetch.
    public func pokeCloudPoll() {
        syncInbox?.fetchNow()
    }

    /// A pairing record changed server-side; if it's one of ours in `waiting`,
    /// run the shared acceptance flow.
    func checkCloudPairingSession(_ rendezvousID: String) async {
        guard let mailbox = cloudMailbox else { return }
        guard pairingSessionState(rendezvousID) == "waiting" else { return }
        do {
            let (pairing, _) = try await mailbox.fetchPairingSession(rendezvousID: rendezvousID)
            guard pairing.state == "responded",
                  let ephemeral = pairing.mobileEphemeralPublicKey,
                  let ciphertext = pairing.encryptedMobileResponse else { return }
            if case .failure(let rejection) = acceptPairingResponse(rendezvousID: rendezvousID,
                                                                    phoneEphemeral: ephemeral,
                                                                    ciphertext: ciphertext) {
                event("cloud pairing rejected: \(rejection.message)")
                await mailbox.deletePairingSession(rendezvousID: rendezvousID)
            }
        } catch CloudKitMailbox.MailboxError.recordMissing {
            return
        } catch {
            event("pairing check error: \(error)")
        }
    }
}
