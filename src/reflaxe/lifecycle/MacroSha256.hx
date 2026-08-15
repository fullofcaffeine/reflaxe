package reflaxe.lifecycle;

#if macro
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	Computes SHA-256 efficiently inside Haxe's macro interpreter.

	The standard cross-target implementation first expands the complete input into
	an integer array and emulates 32-bit addition for targets whose numbers are not
	native 32-bit integers. Macro execution uses Haxe's evaluator, where bitwise
	operations already provide the required 32-bit behavior. Processing one block
	at a time avoids retaining another compiler-sized copy of a rendered typed body.
**/
class MacroSha256 {
	static final ROUND_CONSTANTS:Vector<Int> = Vector.fromArrayCopy([
		0x428A2F98,
		0x71374491,
		0xB5C0FBCF,
		0xE9B5DBA5,
		0x3956C25B,
		0x59F111F1,
		0x923F82A4,
		0xAB1C5ED5,
		0xD807AA98,
		0x12835B01,
		0x243185BE,
		0x550C7DC3,
		0x72BE5D74,
		0x80DEB1FE,
		0x9BDC06A7,
		0xC19BF174,
		0xE49B69C1,
		0xEFBE4786,
		0xFC19DC6,
		0x240CA1CC,
		0x2DE92C6F,
		0x4A7484AA,
		0x5CB0A9DC,
		0x76F988DA,
		0x983E5152,
		0xA831C66D,
		0xB00327C8,
		0xBF597FC7,
		0xC6E00BF3,
		0xD5A79147,
		0x06CA6351,
		0x14292967,
		0x27B70A85,
		0x2E1B2138,
		0x4D2C6DFC,
		0x53380D13,
		0x650A7354,
		0x766A0ABB,
		0x81C2C92E,
		0x92722C85,
		0xA2BFE8A1,
		0xA81A664B,
		0xC24B8B70,
		0xC76C51A3,
		0xD192E819,
		0xD6990624,
		0xF40E3585,
		0x106AA070,
		0x19A4C116,
		0x1E376C08,
		0x2748774C,
		0x34B0BCB5,
		0x391C0CB3,
		0x4ED8AA4A,
		0x5B9CCA4F,
		0x682E6FF3,
		0x748F82EE,
		0x78A5636F,
		0x84C87814,
		0x8CC70208,
		0x90BEFFFA,
		0xA4506CEB,
		0xBEF9A3F7,
		0xC67178F2
	]);

	/** Returns the same lowercase SHA-256 digest as `haxe.crypto.Sha256.encode`. **/
	public static function encode(value:String):String {
		final inputBytes = Bytes.ofString(value);
		final inputLength = #if target.unicode inputBytes.length #else value.length #end;
		final blockCount = (inputLength + 72) >> 6;
		final paddedLength = blockCount << 6;
		final bitLengthLow = inputLength << 3;
		final bitLengthHigh = inputLength >>> 29;
		final encodedBitLength = value.length << 3;
		final encodedPaddingWord = encodedBitLength >> 5;
		final encodedLengthWord = ((encodedBitLength + 64 >> 9) << 4) + 15;
		final words = new Vector<Int>(64);

		var h0 = 0x6A09E667;
		var h1 = 0xBB67AE85;
		var h2 = 0x3C6EF372;
		var h3 = 0xA54FF53A;
		var h4 = 0x510E527F;
		var h5 = 0x9B05688C;
		var h6 = 0x1F83D9AB;
		var h7 = 0x5BE0CD19;

		for (block in 0...blockCount) {
			final blockOffset = block << 6;
			for (index in 0...16) {
				final byteOffset = blockOffset + (index << 2);
				words[index] = (paddedUnit(value, inputBytes, inputLength, byteOffset, paddedLength, bitLengthLow,
					bitLengthHigh) << 24) | (paddedUnit(value, inputBytes, inputLength, byteOffset + 1, paddedLength, bitLengthLow,
						bitLengthHigh) << 16) | (paddedUnit(value, inputBytes, inputLength, byteOffset + 2, paddedLength, bitLengthLow,
							bitLengthHigh) << 8) | paddedUnit(value, inputBytes, inputLength, byteOffset + 3, paddedLength, bitLengthLow, bitLengthHigh);
			}
			final firstWord = block << 4;
			if (encodedPaddingWord >= firstWord && encodedPaddingWord < firstWord + 16)
				words[encodedPaddingWord - firstWord] |= 0x80 << (24 - encodedBitLength % 32);
			if (encodedLengthWord >= firstWord && encodedLengthWord < firstWord + 16)
				words[encodedLengthWord - firstWord] = encodedBitLength;
			for (index in 16...64) {
				final previous15 = words[index - 15];
				final previous2 = words[index - 2];
				final sigma0 = rotateRight(previous15, 7) ^ rotateRight(previous15, 18) ^ (previous15 >>> 3);
				final sigma1 = rotateRight(previous2, 17) ^ rotateRight(previous2, 19) ^ (previous2 >>> 10);
				words[index] = add4(words[index - 16], sigma0, words[index - 7], sigma1);
			}

			var a = h0;
			var b = h1;
			var c = h2;
			var d = h3;
			var e = h4;
			var f = h5;
			var g = h6;
			var h = h7;
			for (index in 0...64) {
				final sigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
				final choice = (e & f) ^ (~e & g);
				final temporary1 = add5(h, sigma1, choice, ROUND_CONSTANTS[index], words[index]);
				final sigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
				final majority = (a & b) ^ (a & c) ^ (b & c);
				final temporary2 = add2(sigma0, majority);
				h = g;
				g = f;
				f = e;
				e = add2(d, temporary1);
				d = c;
				c = b;
				b = a;
				a = add2(temporary1, temporary2);
			}

			h0 = add2(h0, a);
			h1 = add2(h1, b);
			h2 = add2(h2, c);
			h3 = add2(h3, d);
			h4 = add2(h4, e);
			h5 = add2(h5, f);
			h6 = add2(h6, g);
			h7 = add2(h7, h);
		}

		return [h0, h1, h2, h3, h4, h5, h6, h7].map(value -> StringTools.hex(value, 8)).join("").toLowerCase();
	}

	static inline function paddedUnit(value:String, inputBytes:Bytes, inputLength:Int, index:Int, paddedLength:Int, bitLengthLow:Int, bitLengthHigh:Int):Int {
		if (index < inputLength) {
			#if target.unicode
			return inputBytes.get(index);
			#else
			return value.charCodeAt(index) ?? 0;
			#end
		}
		if (index == inputLength)
			return 0x80;
		final distanceFromEnd = paddedLength - 1 - index;
		if (distanceFromEnd < 0 || distanceFromEnd > 7)
			return 0;
		final shift = (distanceFromEnd & 3) << 3;
		return distanceFromEnd < 4 ? (bitLengthLow >>> shift) & 0xFF : (bitLengthHigh >>> shift) & 0xFF;
	}

	static inline function rotateRight(value:Int, distance:Int):Int
		return (value >>> distance) | (value << (32 - distance));

	static inline function add2(first:Int, second:Int):Int
		return (first + second) | 0;

	static inline function add4(first:Int, second:Int, third:Int, fourth:Int):Int
		return (first + second + third + fourth) | 0;

	static inline function add5(first:Int, second:Int, third:Int, fourth:Int, fifth:Int):Int
		return (first + second + third + fourth + fifth) | 0;
}
#end
