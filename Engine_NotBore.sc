// Engine_NotBore.sc
//
// The SuperCollider side of the "i am not bore" norns script.
//
// Eight independent sample voices, one per Turing-machine track. All of the
// sequencing lives in Lua -- this engine is a dumb, fast trigger target:
//
//     loadSlot(track, slot, path)   read a file into one pool slot
//     trig(track, slot, rate)       fire a one-shot voice from that slot
//
// Command names avoid `load`, `free` and `name`: norns' own Engine table
// already defines those, so a command sharing one of those names is shadowed
// by the core function and never reaches the engine.
//
// WHY A POOL, NOT A LIBRARY
// The sample library is ~300 MB across ~2900 stereo files, which is both too
// much RAM and (at 2900) more buffers than scsynth's default table holds. So
// each track owns a small pool of loaded buffers (Lua uses 16) and triggers
// from that:
//
//   slot 0            reserved for the track's FIXED sample
//   slot 1..poolMax-1 the random pool
//
// The pool holds still until Lua re-deals it -- 15 fresh loadSlot calls for
// one track, on demand. Nothing here polls or refreshes on its own.
//
// Re-dealing does not interrupt playback, because a slot keeps its existing
// buffer until the new read completes; the pool crosses over sound by sound
// rather than going quiet. And since replacing a live slot could otherwise
// yank a buffer out from under a sounding voice, the old buffer is kept alive
// for a couple of seconds before it is freed.
//
// SIGNAL PATH
//   PlayBuf -> linen env -> track pan -> track level -> master level -> out
//
// Track level/pan are control busses rather than synth args, so a running
// voice keeps following them -- that is what makes the K3 double-press fade
// duck the tails of already-sounding samples instead of only the next trigger.
// Master level is driven by a VarLag so the fade is a true linear ramp over
// the requested time (a plain Lag would only reach ~63% of the way there).

Engine_NotBore : CroneEngine {

	// per-track arrays of Buffers, indexed [track][slot]. entries are nil
	// until loaded. tracks and slots are 0-based over the wire.
	var <buffers;

	// control busses: one level + one pan per track, plus a single master.
	var <levelBus, <panBus, <masterBus;

	// the synth that writes the (ramped) master level onto masterBus.
	var <masterSynth;

	// voices live here so a panic can free them in one call. ctlGroup runs at
	// the head so the master level for this block is written before the voices
	// in voiceGroup read it.
	var <ctlGroup, <voiceGroup;

	// how many slots each track can hold. allocated generously -- Lua decides
	// how many it actually uses, this is just the ceiling for bounds checks.
	var <poolMax = 64;

	var <numTracks = 8;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		// crone hands the output bus over differently between builds: sometimes
		// a single multichannel Bus, sometimes an Array of mono Busses. the
		// channels are consecutive either way, so take the starting index.
		// (var must be declared up here: SC requires all var declarations at
		// the top of the function.)
		var busIndex = { arg b; if(b.isKindOf(Array)) { b.first.index } { b.index } };
		var out;

		buffers = Array.fill(numTracks, { Array.newClear(poolMax) });

		levelBus = Array.fill(numTracks, { Bus.control(context.server, 1) });
		panBus   = Array.fill(numTracks, { Bus.control(context.server, 1) });
		masterBus = Bus.control(context.server, 1);

		// starting values, in case a voice fires before Lua has pushed state.
		levelBus.do { arg b; b.set(0.7) };
		panBus.do   { arg b; b.set(0.0) };
		masterBus.set(1.0);

		ctlGroup   = Group.head(context.xg);
		voiceGroup = Group.tail(context.xg);

		// --- master level ramp ------------------------------------------------
		// VarLag with a LINEAR warp, so "fade over 3 seconds" means exactly
		// that. setMaster sets lagTime and value together, so the ramp length
		// is whatever the caller asked for on that message.
		//
		// The warp must be `\lin`, not 0. VarLag resolves it with
		//     curve = Env.shapeNames[warp] ? warp
		// and shapeNames is keyed by symbols, so a numeric 0 misses the lookup
		// and falls through as curve 0 -- which is the \step shape, an instant
		// jump. The fade would not fade at all, it would just cut.
		SynthDef(\notbore_master, { arg bus = 0, value = 1, lagTime = 0.02;
			Out.kr(bus, VarLag.kr(value, lagTime, warp: \lin));
		}).add;

		// --- the voice --------------------------------------------------------
		// one one-shot per trigger. built twice, for mono and stereo files:
		// PlayBuf needs its channel count fixed at SynthDef time, and the
		// library is a mix of both. the engine picks the right one at trigger
		// time from the buffer's own numChannels.
		//
		// rate is captured when the voice starts and does not track E2 while
		// the sample sounds -- the samples are all under ~1.5 s, so the next
		// trigger picks up the new speed. this is what lets the envelope know
		// its own length up front.
		//
		//   rate < 0 -> play backwards, so start at the last frame instead of 0
		//   dur      -> buffer length scaled by |rate|, so the release still
		//               lands at the end of the sample at 4x or at 0.25x
		[[\notbore_mono, 1], [\notbore_stereo, 2]].do { arg pair;
			var name = pair[0], numChannels = pair[1];

			SynthDef(name, { arg out = 0, buf = 0, rate = 1,
				lvlBus = 0, pnBus = 0, mstBus = 0;

				var frames, dur, startPos, sig, env, amp, pan;

				frames = BufFrames.kr(buf);

				// how long this voice will sound for. clipped so a near-zero
				// rate can never strand a voice running for minutes (Lua also
				// refuses to trigger inside the E2 dead zone, but the engine
				// should not depend on the caller behaving).
				dur = (BufDur.kr(buf) / rate.abs.max(0.01)).clip(0.02, 30);

				// backwards playback starts at the tail of the buffer.
				startPos = Select.kr(rate < 0, [DC.kr(0), frames - 1]);

				// BufRateScale corrects for the file being 44.1k while the
				// server runs at 48k, so 1.0 really is original pitch.
				sig = PlayBuf.ar(numChannels, buf,
					rate * BufRateScale.kr(buf),
					1, startPos, loop: 0, doneAction: Done.none);

				// short linen: 3 ms in to kill the click on a reversed start,
				// 5 ms out, sustain filling the rest. this env -- not PlayBuf
				// -- owns the voice's lifetime and frees it.
				env = EnvGen.ar(
					Env.linen(0.003, (dur - 0.008).max(0.001), 0.005),
					doneAction: Done.freeSelf);

				// read the track's live level/pan every block, so fades and
				// pan moves reach voices that are already sounding.
				amp = Lag.kr(In.kr(lvlBus), 0.02);
				pan = Lag.kr(In.kr(pnBus), 0.05);

				sig = if(numChannels > 1) {
					// Balance2 keeps a stereo file stereo and leans it, rather
					// than collapsing it to mono first.
					Balance2.ar(sig[0], sig[1], pan)
				} {
					Pan2.ar(sig, pan)
				};

				Out.ar(out, sig * env * amp * Lag.kr(In.kr(mstBus), 0.02));
			}).add;
		};

		// register the SynthDefs before instantiating anything.
		context.server.sync;

		masterSynth = Synth.new(\notbore_master,
			[\bus, masterBus.index, \value, 1.0, \lagTime, 0.02],
			ctlGroup);

		out = busIndex.(context.out_b);

		// --- commands ---------------------------------------------------------

		// read a file into one pool slot. asynchronous: the slot stays at its
		// previous contents (or nil) until the read lands.
		this.addCommand("loadSlot", "iis", { arg msg;
			this.loadSlot(msg[1].asInteger, msg[2].asInteger, msg[3].asString);
		});

		// fire one voice. silently does nothing if the slot has not finished
		// loading yet, which is the normal case for the first few steps.
		this.addCommand("trig", "iif", { arg msg;
			var track = msg[1].asInteger;
			var slot  = msg[2].asInteger;
			var rate  = msg[3];
			var buf;

			if(this.validSlot(track, slot)) {
				buf = buffers[track][slot];
				if(buf.notNil and: { buf.numFrames.notNil } and: { buf.numFrames > 0 }) {
					Synth.new(
						if(buf.numChannels > 1) { \notbore_stereo } { \notbore_mono },
						[
							\out,    out,
							\buf,    buf.bufnum,
							\rate,   rate,
							\lvlBus, levelBus[track].index,
							\pnBus,  panBus[track].index,
							\mstBus, masterBus.index
						],
						voiceGroup
					);
				};
			};
		});

		this.addCommand("trackLevel", "if", { arg msg;
			var track = msg[1].asInteger;
			if(track >= 0 and: { track < numTracks }) {
				levelBus[track].set(msg[2]);
			};
		});

		this.addCommand("trackPan", "if", { arg msg;
			var track = msg[1].asInteger;
			if(track >= 0 and: { track < numTracks }) {
				panBus[track].set(msg[2].clip(-1, 1));
			};
		});

		// master level with an explicit ramp time. K3 double-press calls
		// setMaster(0, fadeTime); everything else uses a short time.
		this.addCommand("setMaster", "ff", { arg msg;
			masterSynth.set(\lagTime, msg[2].max(0.0), \value, msg[1]);
		});

		// free every sounding voice immediately (used on cleanup / panic).
		// takes an ignored float rather than no arguments: a zero-argument
		// command is the one shape of addCommand that is inconsistent across
		// crone builds, and one dummy float costs nothing.
		this.addCommand("panic", "f", { arg msg;
			voiceGroup.freeAll;
		});
	}

	// bounds check shared by load and trig.
	validSlot { arg track, slot;
		^(track >= 0 and: { track < numTracks }
			and: { slot >= 0 } and: { slot < poolMax });
	}

	// read `path` into [track][slot], keeping whatever was there alive for a
	// couple of seconds so a voice sounding from the old buffer is not cut off
	// mid-note when the background pool refresh recycles its slot.
	loadSlot { arg track, slot, path;
		var old;

		if(this.validSlot(track, slot).not) { ^this };
		if(File.exists(path).not) {
			"Engine_NotBore: missing file %".format(path).warn;
			^this;
		};

		old = buffers[track][slot];

		Buffer.read(context.server, path, action: { arg b;
			buffers[track][slot] = b;
			if(old.notNil) {
				SystemClock.sched(2.0, { old.free; nil });
			};
		});
	}

	free {
		voiceGroup.freeAll;
		masterSynth.free;
		ctlGroup.free;
		voiceGroup.free;
		buffers.do { arg track; track.do { arg b; if(b.notNil) { b.free } } };
		levelBus.do { arg b; b.free };
		panBus.do { arg b; b.free };
		masterBus.free;
	}
}
