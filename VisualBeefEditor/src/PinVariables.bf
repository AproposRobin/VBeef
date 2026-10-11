using System;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// The pin context menu's Make variable / Make local variable / Make variable (Get)
	/// (GraphPanel.MakeVariableFromPin): the type the new variable gets from the pin, and the
	/// member variable itself.
	extension EditorApp
	{
		/// The type a variable made from `pin` gets: the pin's type, when Beef takes it for a member
		/// variable (`member`) or a Local. False with the reason otherwise.
		public bool PinVariableType(MethodGraph mg, Pin pin, bool member, String outType, String outWhy)
		{
			if (mg == null || mg.Graph == null || mg.Graph.ReadOnly)
			{
				outWhy.Set("This Sheet cannot be edited.");
				return false;
			}
			if (member && mg.Owner == null)
			{
				outWhy.Set("This function is not in a type, so there is no variable list to add to.");
				return false;
			}
			NodeMenu.NormalizeType(pin.TypeName, outType);
			outType.Trim();
			if (outType.IsEmpty || outType == "var" || outType == "let" || TypeRules.IsGenericParam(outType) || TypeRules.IsWildcard(outType))
			{
				outWhy.Set("The pin's type is not known yet: wire it first, or make the variable in the Outline.");
				return false;
			}
			if (outType == "void")
			{
				outWhy.Set("This pin has no value (void).");
				return false;
			}
			String gen = scope .();
			delegate bool(StringView) known = scope (n) => ProjectHasType(n);
			if (!TypeSlotRules.Check(outType, member ? .Member : .Local, TypeScopeOf(mg.Method, gen, known), outWhy))
				return false;
			return true;
		}

		/// Adds the member variable `m<Base>` (unique in the type) of `type`, with no initial value.
		/// Its own text edit (one undo step); the caller merges the node edit into it.
		public bool MakeMemberForPin(MethodGraph mg, StringView baseName, StringView type, String outName)
		{
			if (!CheckWritable())
				return false;
			let owner = mg.Owner;
			String stem = scope .("m");
			stem.Append(baseName);
			if (stem.Length > 1)
				stem[1] = stem[1].ToUpper;
			outName.Set(stem);
			bool Taken(StringView n)
			{
				if (owner.Members != null)
					for (let m in owner.Members)
						if (m.Name == n)
							return true;
				return false;
			}
			for (int i = 2; Taken(outName); i++)
			{
				outName.Set(stem);
				outName.AppendF("{}", i);
			}
			return AddVariableChecked(mg.Doc, owner, type, outName, "");
		}
	}
}
