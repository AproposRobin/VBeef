// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// Adapted from an updater by the same owner (Update/Ed25519.bf, same licence); the Ed25519
// arithmetic is a port of TweetNaCl (public domain). Changed here: the namespace, comments, and the constants L and
// gf1 are filled by the static constructor (a Debug-build workaround, see L).

using System;

namespace VisualBeef.Update
{
	/// SHA-512 (FIPS 180-4), used by Ed25519.
	public struct Sha512
	{
		private static readonly uint64[80] K = .(
			0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
			0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
			0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
			0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
			0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
			0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
			0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
			0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
			0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
			0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
			0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
			0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
			0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
			0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
			0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
			0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817);

		private uint64[8] mH;
		private uint8[128] mBuffer;
		private int mBuffered;
		private uint64 mLength;

		public this()
		{
			mH = .(0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
				0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179);
			mBuffer = default;
			mBuffered = 0;
			mLength = 0;
		}

		[Inline]
		private static uint64 Rotr(uint64 X, int N) => (X >> N) | (X << (64 - N));

		private void Block(uint8* Data) mut
		{
			uint64[80] W = ?;

			for(int Index = 0; Index < 16; Index++)
			{
				uint64 Value = 0;
				for(int Byte = 0; Byte < 8; Byte++)
					Value = (Value << 8) | Data[Index * 8 + Byte];
				W[Index] = Value;
			}

			for(int Index = 16; Index < 80; Index++)
			{
				uint64 S0 = Rotr(W[Index - 15], 1) ^ Rotr(W[Index - 15], 8) ^ (W[Index - 15] >> 7);
				uint64 S1 = Rotr(W[Index - 2], 19) ^ Rotr(W[Index - 2], 61) ^ (W[Index - 2] >> 6);
				W[Index] = W[Index - 16] &+ S0 &+ W[Index - 7] &+ S1;
			}

			uint64 A = mH[0], B = mH[1], C = mH[2], D = mH[3], E = mH[4], F = mH[5], G = mH[6], H = mH[7];

			for(int Index = 0; Index < 80; Index++)
			{
				uint64 T1 = H &+ (Rotr(E, 14) ^ Rotr(E, 18) ^ Rotr(E, 41)) &+ ((E & F) ^ (~E & G)) &+ K[Index] &+ W[Index];
				uint64 T2 = (Rotr(A, 28) ^ Rotr(A, 34) ^ Rotr(A, 39)) &+ ((A & B) ^ (A & C) ^ (B & C));
				H = G;
				G = F;
				F = E;
				E = D &+ T1;
				D = C;
				C = B;
				B = A;
				A = T1 &+ T2;
			}

			mH[0] &+= A; mH[1] &+= B; mH[2] &+= C; mH[3] &+= D;
			mH[4] &+= E; mH[5] &+= F; mH[6] &+= G; mH[7] &+= H;
		}

		public void Update(Span<uint8> Data) mut
		{
			mLength &+= (uint64)Data.Length;
			int Offset = 0;

			while(Offset < Data.Length)
			{
				int Take = Math.Min(128 - mBuffered, Data.Length - Offset);
				Internal.MemCpy(&mBuffer[mBuffered], &Data[Offset], Take);
				mBuffered += Take;
				Offset += Take;

				if(mBuffered == 128)
				{
					Block(&mBuffer[0]);
					mBuffered = 0;
				}
			}
		}

		public void Final(uint8* Out64) mut
		{
			uint64 BitLength = mLength << 3;
			mBuffer[mBuffered++] = 0x80;

			if(mBuffered > 112)
			{
				while(mBuffered < 128)
					mBuffer[mBuffered++] = 0;
				Block(&mBuffer[0]);
				mBuffered = 0;
			}

			while(mBuffered < 120)
				mBuffer[mBuffered++] = 0;

			for(int Byte = 0; Byte < 8; Byte++)
				mBuffer[120 + Byte] = (uint8)(BitLength >> (56 - Byte * 8));

			Block(&mBuffer[0]);

			for(int Index = 0; Index < 8; Index++)
			{
				for(int Byte = 0; Byte < 8; Byte++)
					Out64[Index * 8 + Byte] = (uint8)(mH[Index] >> (56 - Byte * 8));
			}
		}

		public static void Hash(Span<uint8> Data, uint8* Out64)
		{
			var Hasher = Sha512();
			Hasher.Update(Data);
			Hasher.Final(Out64);
		}
	}

	/// Ed25519 (RFC 8032, pure Ed25519, no context): verification for signed VisualBeef releases (release.json), plus signing, which only
	/// the self test uses. A port of TweetNaCl's crypto_sign / crypto_sign_open (public domain), with two strictness
	/// additions: the S half of a signature must be below the group order L (no malleable signatures), and the public
	/// key must decode to a curve point. Field elements are 16 limbs of 16 bits in int64 (Gf); a point is 4 field elements
	/// (X, Y, Z, T) laid out in an int64[64]. Verification handles public data only, so it does not need to be constant
	/// time; the signing path is used by tests with test keys only.
	public static class Ed25519
	{
		public const int PublicKeySize = 32;
		public const int SignatureSize = 64;
		public const int SeedSize = 32;

		private typealias Gf = int64[16];
		private typealias Point = int64[64];

		private static readonly Gf gf0 = default;
		/// 1 (set in the static constructor, see L).
		private static Gf gf1;
		private static readonly Gf D = .(0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203);
		private static readonly Gf D2 = .(0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406);
		private static readonly Gf X = .(0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169);
		private static readonly Gf Y = .(0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666);
		private static readonly Gf I = .(0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83);
		/// The group order L = 2^252 + 27742317777372353535851937790883648493, little endian.
		/// Filled by the static constructor: in Debug builds (Beef 0.43.6) a static readonly int64[32] initialised with a
		/// list ending in a run of zeros came out with garbage in its last element, so every signature failed.
		private static int64[32] L;

		static this()
		{
			uint8[16] low = .(0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14);
			for (int i < 32)
				L[i] = 0;
			for (int i < 16)
				L[i] = low[i];
			L[31] = 0x10;
			for (int i < 16)
				gf1[i] = 0;
			gf1[0] = 1;
		}

		// ----- Field arithmetic mod 2^255 - 19 -----

		private static void Set(int64* R, int64* A)
		{
			for(int Index = 0; Index < 16; Index++)
				R[Index] = A[Index];
		}

		private static void Carry(int64* O)
		{
			for(int Index = 0; Index < 16; Index++)
			{
				O[Index] += (1L << 16);
				int64 C = O[Index] >> 16;

				if(Index < 15)
					O[Index + 1] += C - 1;
				else
					O[0] += 38 * (C - 1);

				O[Index] -= C << 16;
			}
		}

		private static void Select(int64* P, int64* Q, int32 B)
		{
			int64 C = ~((int64)B - 1);

			for(int Index = 0; Index < 16; Index++)
			{
				int64 T = C & (P[Index] ^ Q[Index]);
				P[Index] ^= T;
				Q[Index] ^= T;
			}
		}

		private static void Pack25519(uint8* O, int64* N)
		{
			Gf M = default;
			Gf T = default;

			for(int Index = 0; Index < 16; Index++)
				T[Index] = N[Index];

			Carry(&T[0]);
			Carry(&T[0]);
			Carry(&T[0]);

			for(int Pass = 0; Pass < 2; Pass++)
			{
				M[0] = T[0] - 0xffed;

				for(int Index = 1; Index < 15; Index++)
				{
					M[Index] = T[Index] - 0xffff - ((M[Index - 1] >> 16) & 1);
					M[Index - 1] &= 0xffff;
				}

				M[15] = T[15] - 0x7fff - ((M[14] >> 16) & 1);
				int32 B = (int32)((M[15] >> 16) & 1);
				M[14] &= 0xffff;
				Select(&T[0], &M[0], 1 - B);
			}

			for(int Index = 0; Index < 16; Index++)
			{
				O[2 * Index] = (uint8)(T[Index] & 0xff);
				O[2 * Index + 1] = (uint8)((T[Index] >> 8) & 0xff);
			}
		}

		private static bool Equal32(uint8* A, uint8* B)
		{
			int32 Diff = 0;

			for(int Index = 0; Index < 32; Index++)
				Diff |= A[Index] ^ B[Index];

			return Diff == 0;
		}

		private static bool NotEqual25519(int64* A, int64* B)
		{
			uint8[32] C = ?;
			uint8[32] D = ?;
			Pack25519(&C[0], A);
			Pack25519(&D[0], B);
			return !Equal32(&C[0], &D[0]);
		}

		private static uint8 Parity25519(int64* A)
		{
			uint8[32] D = ?;
			Pack25519(&D[0], A);
			return D[0] & 1;
		}

		private static void Unpack25519(int64* O, uint8* N)
		{
			for(int Index = 0; Index < 16; Index++)
				O[Index] = (int64)N[2 * Index] + ((int64)N[2 * Index + 1] << 8);

			O[15] &= 0x7fff;
		}

		private static void Add(int64* O, int64* A, int64* B)
		{
			for(int Index = 0; Index < 16; Index++)
				O[Index] = A[Index] + B[Index];
		}

		private static void Sub(int64* O, int64* A, int64* B)
		{
			for(int Index = 0; Index < 16; Index++)
				O[Index] = A[Index] - B[Index];
		}

		private static void Mul(int64* O, int64* A, int64* B)
		{
			int64[31] T = default;

			for(int I = 0; I < 16; I++)
			{
				for(int J = 0; J < 16; J++)
					T[I + J] += A[I] * B[J];
			}

			for(int Index = 0; Index < 15; Index++)
				T[Index] += 38 * T[Index + 16];

			for(int Index = 0; Index < 16; Index++)
				O[Index] = T[Index];

			Carry(O);
			Carry(O);
		}

		private static void Square(int64* O, int64* A) => Mul(O, A, A);

		private static void Inverse25519(int64* O, int64* In)
		{
			Gf C = default;
			Set(&C[0], In);

			for(int A = 253; A >= 0; A--)
			{
				Square(&C[0], &C[0]);
				if(A != 2 && A != 4)
					Mul(&C[0], &C[0], In);
			}

			Set(O, &C[0]);
		}

		private static void Pow2523(int64* O, int64* In)
		{
			Gf C = default;
			Set(&C[0], In);

			for(int A = 250; A >= 0; A--)
			{
				Square(&C[0], &C[0]);
				if(A != 1)
					Mul(&C[0], &C[0], In);
			}

			Set(O, &C[0]);
		}

		// ----- Points (extended coordinates, 4 x 16 limbs) -----

		private static void PointAdd(int64* P, int64* Q)
		{
			Gf A = ?, B = ?, C = ?, Dd = ?, T = ?, E = ?, F = ?, G = ?, H = ?;
			var D2Copy = D2;

			Sub(&A[0], P + 16, P);
			Sub(&T[0], Q + 16, Q);
			Mul(&A[0], &A[0], &T[0]);
			Add(&B[0], P, P + 16);
			Add(&T[0], Q, Q + 16);
			Mul(&B[0], &B[0], &T[0]);
			Mul(&C[0], P + 48, Q + 48);
			Mul(&C[0], &C[0], &D2Copy[0]);
			Mul(&Dd[0], P + 32, Q + 32);
			Add(&Dd[0], &Dd[0], &Dd[0]);
			Sub(&E[0], &B[0], &A[0]);
			Sub(&F[0], &Dd[0], &C[0]);
			Add(&G[0], &Dd[0], &C[0]);
			Add(&H[0], &B[0], &A[0]);

			Mul(P, &E[0], &F[0]);
			Mul(P + 16, &H[0], &G[0]);
			Mul(P + 32, &G[0], &F[0]);
			Mul(P + 48, &E[0], &H[0]);
		}

		private static void CSwap(int64* P, int64* Q, uint8 B)
		{
			for(int Index = 0; Index < 4; Index++)
				Select(P + Index * 16, Q + Index * 16, B);
		}

		private static void PackPoint(uint8* R, int64* P)
		{
			Gf Tx = ?, Ty = ?, Zi = ?;
			Inverse25519(&Zi[0], P + 32);
			Mul(&Tx[0], P, &Zi[0]);
			Mul(&Ty[0], P + 16, &Zi[0]);
			Pack25519(R, &Ty[0]);
			R[31] ^= Parity25519(&Tx[0]) << 7;
		}

		private static void ScalarMult(int64* P, int64* Q, uint8* S)
		{
			var Zero = gf0;
			var One = gf1;
			Set(P, &Zero[0]);
			Set(P + 16, &One[0]);
			Set(P + 32, &One[0]);
			Set(P + 48, &Zero[0]);

			for(int Index = 255; Index >= 0; Index--)
			{
				uint8 B = (S[Index / 8] >> (Index & 7)) & 1;
				CSwap(P, Q, B);
				PointAdd(Q, P);
				PointAdd(P, P);
				CSwap(P, Q, B);
			}
		}

		private static void ScalarBase(int64* P, uint8* S)
		{
			Point Q = default;
			var Bx = X;
			var By = Y;
			var One = gf1;
			Set(&Q[0], &Bx[0]);
			Set(&Q[16], &By[0]);
			Set(&Q[32], &One[0]);
			Mul(&Q[48], &Bx[0], &By[0]);
			ScalarMult(P, &Q[0], S);
		}

		/// Decodes a point and negates it (-A, what verification needs). False when the bytes are not a curve point.
		private static bool UnpackNeg(int64* R, uint8* P)
		{
			Gf T = ?, Chk = ?, Num = ?, Den = ?, Den2 = ?, Den4 = ?, Den6 = ?;
			var One = gf1;
			var Zero = gf0;
			var Dc = D;
			var Ic = I;

			Set(R + 32, &One[0]);
			Unpack25519(R + 16, P);
			Square(&Num[0], R + 16);
			Mul(&Den[0], &Num[0], &Dc[0]);
			Sub(&Num[0], &Num[0], R + 32);
			Add(&Den[0], R + 32, &Den[0]);

			Square(&Den2[0], &Den[0]);
			Square(&Den4[0], &Den2[0]);
			Mul(&Den6[0], &Den4[0], &Den2[0]);
			Mul(&T[0], &Den6[0], &Num[0]);
			Mul(&T[0], &T[0], &Den[0]);

			Pow2523(&T[0], &T[0]);
			Mul(&T[0], &T[0], &Num[0]);
			Mul(&T[0], &T[0], &Den[0]);
			Mul(&T[0], &T[0], &Den[0]);
			Mul(R, &T[0], &Den[0]);

			Square(&Chk[0], R);
			Mul(&Chk[0], &Chk[0], &Den[0]);
			if(NotEqual25519(&Chk[0], &Num[0]))
				Mul(R, R, &Ic[0]);

			Square(&Chk[0], R);
			Mul(&Chk[0], &Chk[0], &Den[0]);
			if(NotEqual25519(&Chk[0], &Num[0]))
				return false;

			if(Parity25519(R) == (P[31] >> 7))
				Sub(R, &Zero[0], R);

			Mul(R + 48, R, R + 16);
			return true;
		}

		// ----- Scalars mod L -----

		private static void ModL(uint8* R, int64* X)
		{
			int64 Carry;
			int J;

			for(int Index = 63; Index >= 32; Index--)
			{
				Carry = 0;

				for(J = Index - 32; J < Index - 12; J++)
				{
					X[J] += Carry - 16 * X[Index] * L[J - (Index - 32)];
					Carry = (X[J] + 128) >> 8;
					X[J] -= Carry << 8;
				}

				X[J] += Carry;
				X[Index] = 0;
			}

			Carry = 0;

			for(J = 0; J < 32; J++)
			{
				X[J] += Carry - (X[31] >> 4) * L[J];
				Carry = X[J] >> 8;
				X[J] &= 255;
			}

			for(J = 0; J < 32; J++)
				X[J] -= Carry * L[J];

			for(int Index = 0; Index < 32; Index++)
			{
				X[Index + 1] += X[Index] >> 8;
				R[Index] = (uint8)(X[Index] & 255);
			}
		}

		/// R (64 bytes) := R mod L in its first 32 bytes.
		private static void Reduce(uint8* R)
		{
			int64[64] X = ?;

			for(int Index = 0; Index < 64; Index++)
				X[Index] = R[Index];

			for(int Index = 0; Index < 64; Index++)
				R[Index] = 0;

			ModL(R, &X[0]);
		}

		/// True when the 32-byte little-endian scalar is below L (a canonical S).
		private static bool IsCanonicalScalar(uint8* S)
		{
			for(int Index = 31; Index >= 0; Index--)
			{
				if(S[Index] < L[Index])
					return true;
				if(S[Index] > L[Index])
					return false;
			}

			return false; // equal to L
		}

		// ----- API -----

		/// Verifies a 64-byte Ed25519 signature of Message under a 32-byte public key.
		public static bool Verify(Span<uint8> PublicKey, Span<uint8> Message, Span<uint8> Signature)
		{
			if(PublicKey.Length != PublicKeySize || Signature.Length != SignatureSize)
				return false;

			uint8* Sig = Signature.Ptr;
			uint8* Pk = PublicKey.Ptr;

			if(!IsCanonicalScalar(Sig + 32))
				return false;

			Point P = default;
			Point Q = default;

			if(!UnpackNeg(&Q[0], Pk))
				return false;

			// h = SHA-512(R || A || M) mod L
			uint8[64] H = ?;
			var Hasher = Sha512();
			Hasher.Update(.(Sig, 32));
			Hasher.Update(.(Pk, 32));
			Hasher.Update(Message);
			Hasher.Final(&H[0]);
			Reduce(&H[0]);

			// [h](-A) + [S]B must encode to R.
			ScalarMult(&P[0], &Q[0], &H[0]);
			ScalarBase(&Q[0], Sig + 32);
			PointAdd(&P[0], &Q[0]);

			uint8[32] T = ?;
			PackPoint(&T[0], &P[0]);
			return Equal32(Sig, &T[0]);
		}

		/// The 32-byte public key of a 32-byte seed (RFC 8032 private key).
		public static void PublicKeyFromSeed(Span<uint8> Seed, uint8* OutPublicKey32)
		{
			uint8[64] Dg = ?;
			Sha512.Hash(Seed, &Dg[0]);
			Dg[0] &= 248;
			Dg[31] &= 127;
			Dg[31] |= 64;

			Point P = default;
			ScalarBase(&P[0], &Dg[0]);
			PackPoint(OutPublicKey32, &P[0]);
		}

		/// Signs Message with a 32-byte seed (RFC 8032). Used by in-app release publishing (src/Account/AdminPublish.bf,
		/// the owner's key file read for the sign step only) and the self tests; byte-identical to Node's crypto.sign for
		/// the same seed and message (--selftest-update: RFC 8032 vectors; --selftest-admin-publish: a Node signature).
		public static void Sign(Span<uint8> Seed, Span<uint8> Message, uint8* OutSignature64)
		{
			uint8[64] Dg = ?;
			Sha512.Hash(Seed, &Dg[0]);
			Dg[0] &= 248;
			Dg[31] &= 127;
			Dg[31] |= 64;

			uint8[32] Pk = ?;
			PublicKeyFromSeed(Seed, &Pk[0]);

			// r = SHA-512(prefix || M) mod L
			uint8[64] R = ?;
			var Hasher = Sha512();
			Hasher.Update(.(&Dg[32], 32));
			Hasher.Update(Message);
			Hasher.Final(&R[0]);
			Reduce(&R[0]);

			Point P = default;
			ScalarBase(&P[0], &R[0]);
			PackPoint(OutSignature64, &P[0]);

			// h = SHA-512(R || A || M) mod L
			uint8[64] H = ?;
			var Hasher2 = Sha512();
			Hasher2.Update(.(OutSignature64, 32));
			Hasher2.Update(.(&Pk[0], 32));
			Hasher2.Update(Message);
			Hasher2.Final(&H[0]);
			Reduce(&H[0]);

			// S = r + h * a mod L
			int64[64] Xs = default;

			for(int Index = 0; Index < 32; Index++)
				Xs[Index] = R[Index];

			for(int I = 0; I < 32; I++)
			{
				for(int J = 0; J < 32; J++)
					Xs[I + J] += (int64)H[I] * (int64)Dg[J];
			}

			ModL(OutSignature64 + 32, &Xs[0]);
		}
	}
}
