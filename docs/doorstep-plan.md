# Doorstep update

- Accept always wins: cancel the outgoing visit, stop its media, ignore late admission, then accept the selected visitor.
- Keep remote cancellation best effort so poor connectivity cannot block acceptance.
- Fade call windows and audio independently; respect Reduce Motion.
- Quiet two-way doorstep voices; Listen raises only that preview to full volume.
- Never send doorstep audio from an existing call, during Quiet Door (or Focus in provisioned builds), or while another app records audio.
- Notch moon enables Quiet Door for six hours; persists across restart/update and expires after sleep. Tap again to end early.
- The xattr beta uses manual Quiet Door, not macOS Focus. Other-app mic/camera checks remain automatic. Provisioned builds may also request Focus access.
- Open Door Policy: first settings card, off by default, saved to the account; accepted friends may enter while the owner app is available.
- Recheck policy before admission; turning it off cannot leave stale permission behind.
- Keep each visitor in an isolated preview room; owner preview publishes microphone only.
- Fix dropped microphone changes and stale input-device selection; show permission failures.
- Verify cancellation races, privacy transitions, policy ownership/revocation, microphone state, and real local client/media flows.
- Build a matching app/backend candidate; production code deployment is a separate reviewed step.
