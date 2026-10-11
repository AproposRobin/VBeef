// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;

namespace VisualBeef.Update
{
	/// The release signing key(s) this build trusts (docs/Releasing.md, "The signing key").
	///
	/// THE ONE PLACE THE PUBLIC KEY LIVES. Paste the base64 public key that `node scripts/release.mjs keygen` printed
	/// (the content of the `.pub` file) between the quotes and commit. Several keys (a rotation) are separated by ';'.
	/// Never put the private key here or anywhere in the repository.
	///
	/// Empty: this build trusts no key, so the updater refuses every release descriptor and the editor says that updates
	/// are not set up in this build (a manual download still works).
	public static class ReleaseKeys
	{
		public const String Keys = "BwL5ikLKlGt/ZfUO6rHmcavIATChDfV1zwTVhB4ZXmo=";
	}
}
