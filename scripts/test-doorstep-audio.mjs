#!/usr/bin/env node
// Disposable local Convex + LiveKit only. Publishes generated tones, never hardware audio.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { ConvexHttpClient } from 'convex/browser';
import { Room, RoomEvent, AudioSource, AudioFrame, AudioStream, LocalAudioTrack, TrackPublishOptions, TrackSource, dispose } from '@livekit/rtc-node';

const endpoint = process.env.DOORBELL_CONVEX_TEST_URL;
assert.equal(new URL(endpoint).hostname, '127.0.0.1', 'Only disposable loopback Convex is allowed');
const clients = [], rooms = [], tracks = [], readers = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(test, description) {
  for (let i = 0; i < 200; i++) { if (test()) return; await delay(50); }
  throw new Error(`Timed out: ${description}`);
}
async function account(label) {
  const client = new ConvexHttpClient(endpoint), handle = `${label}_${randomUUID().slice(0, 8)}`;
  const response = await client.action('auth:signIn', { provider: 'password', params: {
    email: `${handle}@test.local`, password: randomUUID(), flow: 'signUp',
  }});
  assert.ok(response.tokens?.token);
  client.setAuth(response.tokens.token);
  await client.mutation('profiles:claimHandle', { handle, displayName: label });
  clients.push(client);
  return { client, handle };
}
async function join(grant) {
  assert.equal(new URL(grant.url).hostname, '127.0.0.1');
  const room = new Room(); rooms.push(room);
  await room.connect(grant.url, grant.token, { autoSubscribe: true });
  return room;
}
function receive(room) {
  const heard = new Set();
  room.on(RoomEvent.TrackSubscribed, (track, _publication, participant) => {
    const reader = new AudioStream(track).getReader(); readers.push(reader);
    void (async () => {
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value.data.some(sample => Math.abs(sample) > 300)) heard.add(participant.identity);
        }
      } catch {} // Room cleanup ends the stream.
    })();
  });
  return heard;
}
async function tone(room, frequency) {
  const source = new AudioSource(48000, 1), track = LocalAudioTrack.createAudioTrack('test-tone', source);
  tracks.push(track);
  const options = new TrackPublishOptions(); options.source = TrackSource.SOURCE_MICROPHONE;
  await room.localParticipant.publishTrack(track, options);
  for (let block = 0; block < 100; block++) {
    const samples = new Int16Array(480);
    for (let i = 0; i < samples.length; i++) samples[i] = Math.round(8000 * Math.sin(2 * Math.PI * frequency * (block * 480 + i) / 48000));
    await source.captureFrame(new AudioFrame(samples, 48000, 1, 480));
  }
  await source.waitForPlayout();
}
try {
  const guest = await account('guest'), owner = await account('owner');
  const guestProfile = (await guest.client.query('profiles:account', {})).me;
  const ownerProfile = (await owner.client.query('profiles:account', {})).me;
  assert.equal((await owner.client.query('profiles:account', {})).me.openDoorPolicy, false);
  await owner.client.mutation('profiles:setOpenDoorPolicy', { enabled: true });
  await assert.rejects(guest.client.action('doorActions:visit', { door: owner.handle, visitId: randomUUID() }));
  await guest.client.mutation('graph:request', { profileId: ownerProfile.id });
  await assert.rejects(guest.client.action('doorActions:visit', { door: owner.handle, visitId: randomUUID() }));
  await owner.client.mutation('graph:accept', { profileId: guestProfile.id });
  const visitId = randomUUID();
  const grant = await guest.client.action('doorActions:visit', { door: owner.handle, visitId });
  assert.equal(grant.mode, 'walk_in');
  const guestRoom = await join(grant), atGuest = receive(guestRoom);
  await guest.client.action('doorActions:announce', { door: owner.handle, visitId });
  const preview = await owner.client.action('doorActions:answer', { hidden: true, visitId });
  const claims = JSON.parse(Buffer.from(preview.token.split('.')[1], 'base64url'));
  assert.equal(claims.video.hidden, false);
  assert.deepEqual(claims.video.canPublishSources, ['microphone']);
  assert.equal(claims.video.canPublishData, false);
  assert.equal(JSON.parse(claims.metadata).doorbellRole, 'doorstep-preview');
  const ownerRoom = await join(preview), atOwner = receive(ownerRoom);
  await Promise.all([tone(ownerRoom, 440), tone(guestRoom, 660)]);
  await until(() => atGuest.has(owner.handle) && atOwner.has(guest.handle), 'nonzero audio frames both directions');
  await owner.client.mutation('profiles:setOpenDoorPolicy', { enabled: false });
  // Closing automatic entry does not revoke an existing friend's preview.
  await owner.client.action('doorActions:answer', { hidden: true, visitId });
  await owner.client.mutation('graph:unfollow', { profileId: guestProfile.id });
  const events = await owner.client.query('doors:events', {});
  assert.ok(events.some(event => event.visitId === visitId && event.kind === 'left'), 'Removing friendship must tell owner to disconnect the preview');
  await ownerRoom.disconnect();
  await assert.rejects(owner.client.action('doorActions:answer', { hidden: true, visitId }));
  await assert.rejects(guest.client.action('doorActions:visit', { door: owner.handle, visitId: randomUUID() }));
  await guest.client.action('doorActions:leave', { door: owner.handle, visitId });
  console.log('Real Convex grants: friends-only open door, stranger rejection, duplex synthetic audio, microphone-only preview, and friendship revocation passed.');
} finally {
  await Promise.all(readers.map(reader => reader.cancel().catch(() => {})));
  await Promise.all(rooms.map(room => room.disconnect().catch(() => {})));
  await Promise.all(tracks.map(track => track.close(true).catch(() => {})));
  await Promise.all(clients.map(client => client.action('auth:signOut', {}).catch(() => {})));
  await dispose();
}
