using System;
using System.Collections;
using VisualBeef.Catalog;
using VisualBeef.Document;

namespace VisualBeef.Graph
{
	/// The overloads of a call node's function (docs/Calls-and-Receivers.md#overloads): how many
	/// there are, which one the node's pins show, the most specific one for the values wired or
	/// typed into the node, and switching to another one from Properties.
	///
	/// Beef has no syntax that names an overload: the arguments choose it. So the node's pins follow
	/// the overload the arguments choose (a text literal picks `WriteLine(StringView line)`, a wired
	/// int `WriteLine(Object obj)`), and an overload picked in Properties that the arguments would not
	/// choose is written with a Cast on the argument that tells them apart (NodeFactory.PickOverload).
	static class CallOverloads
	{
		// ------------------------------------------------------------------ pin labels

		/// `Console` / `Debug` (`System.Console`, `System.Diagnostics.Debug`) `Write` / `WriteLine`:
		/// corlib's print functions, whose pins get friendly labels.
		public static bool IsPrintFunction(StringView owner, StringView func)
		{
			if (func != "WriteLine" && func != "Write")
				return false;
			var o = owner;
			if (o.StartsWith("System.Diagnostics."))
				o.RemoveFromStart(19);
			else if (o.StartsWith("System."))
				o.RemoveFromStart(7);
			return o == "Console" || o == "Debug";
		}

		/// The pin label for parameter `param` of `owner.function` (`paramCount` parameters): the
		/// print functions' text is the Message (a format text with values is Format and Values);
		/// everything else keeps the parameter's own name.
		public static void FriendlyLabel(StringView owner, StringView func, StringView param, int paramCount, String outLabel)
		{
			String name = scope .(param);
			outLabel.Set(name);
			if (!IsPrintFunction(owner, func))
				return;
			switch (name)
			{
			case "line", "sv", "obj", "text", "value", "str":
				outLabel.Set("Message");
			case "fmt", "strFormat", "format":
				outLabel.Set((paramCount <= 1) ? "Message" : "Format");
			case "args":
				outLabel.Set("Values");
			default:
			}
		}

		// ------------------------------------------------------------------ the list

		/// Where the call's function is looked up: the type before the dot of a static call, the
		/// Receiver's type of a member call (what is wired into it when that is known).
		static bool Where(Graph g, Node call, String staticType, String targetType)
		{
			if (call == null || call.Kind != .Call)
				return false;
			switch (call.Binding)
			{
			case .Static:
				if (call.Qualifier != null && !call.Qualifier.IsEmpty)
					staticType.Set(call.Qualifier);
				else if (call.OwnerType != null)
					staticType.Set(call.OwnerType);
				return !staticType.IsEmpty;
			case .Instance:
				let target = call.FindInput("target");
				let link = (target != null && g != null) ? g.FindLinkTo(target) : null;
				if (link != null && !TypeRules.IsWildcard(link.From.TypeName))
					targetType.Set(link.From.TypeName);
				else if (target != null && !TypeRules.IsWildcard(target.TypeName))
					targetType.Set(target.TypeName);
				else if (call.OwnerType != null)
					targetType.Set(call.OwnerType);
				return !targetType.IsEmpty;
			default:
				return false;
			}
		}

		/// Every overload of the call's function (none for an unresolved call or without a
		/// TypeService). The entries belong to the TypeService.
		public static void ListOf(Graph g, Node call, TypeService ts, List<SymbolMethod> outList)
		{
			if (ts == null)
				return;
			String st = scope .();
			String tt = scope .();
			if (!Where(g, call, st, tt))
				return;
			ts.ListOverloads(st, tt, call.Text, call.Binding == .Static, null, outList);
		}

		/// How many overloads the call's function has (0 when unknown); kept on the node until the
		/// TypeService changes.
		public static int Count(Graph g, Node call, TypeService ts)
		{
			if (ts == null || call == null || call.Kind != .Call || call.Binding == .Unresolved)
				return 0;
			if (call.OverloadCount >= 0 && call.OverloadGen == ts.Generation)
				return call.OverloadCount;
			List<SymbolMethod> list = scope .();
			ListOf(g, call, ts, list);
			call.OverloadCount = (int32)list.Count;
			call.OverloadGen = ts.Generation;
			return list.Count;
		}

		/// `Name(type name, ref type name)`: the form NodeFactory.PickOverload and the ambiguity
		/// list use.
		public static void Signature(SymbolMethod m, String outSig)
		{
			outSig.AppendF("{}(", m.Name);
			for (int i < m.ParamTypes.Count)
			{
				if (i > 0)
					outSig.Append(", ");
				if (i < m.ParamModifiers.Count && !m.ParamModifiers[i].IsEmpty)
					outSig.AppendF("{} ", m.ParamModifiers[i]);
				outSig.AppendF("{} {}", m.ParamTypes[i], m.ParamNames[i]);
			}
			outSig.Append(')');
		}

		/// `WriteLine(StringView)`: the overload the node's pins show, for its subtitle.
		public static void PinSignature(Node call, String outSig)
		{
			outSig.AppendF("{}(", call.Text);
			List<Pin> args = scope .();
			call.GetArgPins(args);
			for (let p in args)
			{
				if (@p.Index > 0)
					outSig.Append(", ");
				if (p.IsOutArg)
					outSig.Append("out ");
				else if (p.IsRefArg)
					outSig.Append("ref ");
				outSig.Append(p.TypeName.IsEmpty ? "?" : (StringView)p.TypeName);
			}
			outSig.Append(')');
		}

		static int ParamsAt(SymbolMethod m)
		{
			for (int i < m.ParamModifiers.Count)
				if (m.ParamModifiers[i].Contains("params"))
					return i;
			return -1;
		}

		static bool IsOutParam(SymbolMethod m, int i)
		{
			let mod = (i < m.ParamModifiers.Count) ? (StringView)m.ParamModifiers[i] : "";
			if (mod == "out")
				return true;
			if (mod != "ref" || i >= m.ParamAttributes.Count)
				return false;
			let a = m.ParamAttributes[i];
			return a.Contains("Pin") && a.Contains("Out") && a.Contains("true");
		}

		static bool SameType(StringView a, StringView b)
		{
			String na = scope .();
			String nb = scope .();
			TypeRules.Normalize(a, na);
			TypeRules.Normalize(b, nb);
			return na == nb || TypeRules.CanConvert(na, nb) == .Exact && TypeRules.CanConvert(nb, na) == .Exact;
		}

		static bool SameParams(SymbolMethod a, SymbolMethod b)
		{
			if (a.ParamTypes.Count != b.ParamTypes.Count)
				return false;
			for (int i < a.ParamTypes.Count)
			{
				if (!SameType(a.ParamTypes[i], b.ParamTypes[i]))
					return false;
				StringView ma = (i < a.ParamModifiers.Count) ? (StringView)a.ParamModifiers[i] : "";
				StringView mb = (i < b.ParamModifiers.Count) ? (StringView)b.ParamModifiers[i] : "";
				if (ma != mb)
					return false;
			}
			return true;
		}

		/// The overload of `list` the node's argument pins show (count and types), or -1.
		public static int IndexOfCurrent(Node call, List<SymbolMethod> list)
		{
			List<Pin> args = scope .();
			call.GetArgPins(args);
			for (let m in list)
			{
				let pa = ParamsAt(m);
				int fixedCount = (pa >= 0) ? pa : m.ParamTypes.Count;
				if (pa >= 0 ? args.Count < fixedCount : args.Count != fixedCount)
					continue;
				bool same = true;
				for (int i < fixedCount)
				{
					let declared = (args[i].WildcardType != null) ? (StringView)args[i].WildcardType : (StringView)args[i].TypeName;
					if (!SameType(declared, m.ParamTypes[i]) && !SameType(args[i].TypeName, m.ParamTypes[i]))
					{
						same = false;
						break;
					}
					if (args[i].IsOutArg != IsOutParam(m, i))
					{
						same = false;
						break;
					}
				}
				if (same)
					return @m.Index;
			}
			return -1;
		}

		// ------------------------------------------------------------------ what the arguments choose

		/// The type each argument brings now: the wire's type, the type of a typed literal, or ""
		/// (unknown: an expression, a name, an out pin).
		public static void ArgTypes(Graph g, Node call, List<String> outTypes)
		{
			List<Pin> args = scope .();
			call.GetArgPins(args);
			for (let p in args)
			{
				String t = new .();
				outTypes.Add(t);
				if (p.IsOutArg)
					continue;
				let link = g.FindLinkTo(p);
				if (link != null)
				{
					if (!TypeRules.IsWildcard(link.From.TypeName))
						t.Set(link.From.TypeName);
				}
				else if (!p.Default.IsEmpty)
				{
					TypeRules.LiteralType(p.Default, t);
					if (t == "null")
						t.Clear();
				}
			}
		}

		/// The overload Beef calls for the arguments as they are now (null when nothing is known).
		public static SymbolMethod Resolve(Graph g, Node call, TypeService ts, bool requireKnown = true)
		{
			if (ts == null)
				return null;
			String st = scope .();
			String tt = scope .();
			if (!Where(g, call, st, tt))
				return null;
			List<String> types = scope .();
			defer { ClearAndDeleteItems!(types); }
			ArgTypes(g, call, types);
			bool any = false;
			for (let t in types)
				if (!t.IsEmpty)
					any = true;
			if (requireKnown && !any)
				return null;
			return ts.ResolveCall(st, tt, call.Text, types.Count, types, null);
		}

		/// True when no argument has a wire or a value (a node just placed): the node then shows
		/// its default overload.
		static bool AllEmpty(Graph g, Node call)
		{
			List<Pin> args = scope .();
			call.GetArgPins(args);
			for (let p in args)
				if (p.IsOutArg || g.IsLinked(p) || !p.Default.IsEmpty)
					return false;
			return true;
		}

		/// How many parameters of the overload take any value as `Object` (a fallback, never the
		/// default choice).
		static int ObjectParams(SymbolMethod m)
		{
			int n = 0;
			for (let t in m.ParamTypes)
				if (TypeRules.BaseName(t) == "Object")
					n++;
			return n;
		}

		/// The most specific overload for what is wired or typed into the call now, with the same
		/// number of arguments; applied when it is not the one the pins show. A node with nothing in
		/// its inputs gets the overload with the fewest `Object` parameters (never the `Object`
		/// overload by default). Ties and unknown types change nothing. True when the pins changed.
		public static bool Refit(Graph g, Node call, TypeService ts)
		{
			if (ts == null || call == null || call.Kind != .Call || call.Binding == .Unresolved || call.Ambiguous)
				return false;
			List<SymbolMethod> list = scope .();
			ListOf(g, call, ts, list);
			if (list.Count < 2)
				return false;
			let cur = IndexOfCurrent(call, list);
			List<Pin> args = scope .();
			call.GetArgPins(args);
			SymbolMethod want = null;
			if (AllEmpty(g, call))
			{
				// The default: the same number of inputs, the fewest Object parameters.
				int best = int.MaxValue;
				for (let m in list)
				{
					if (m.ParamTypes.Count != args.Count || ParamsAt(m) >= 0)
						continue;
					let n = ObjectParams(m);
					if (n < best)
					{
						best = n;
						want = m;
					}
				}
				if (want == null || (cur >= 0 && ObjectParams(list[cur]) <= best))
					return false;
			}
			else
			{
				let r = Resolve(g, call, ts);
				if (r == null || r.Ambiguous)
					return false;
				for (let m in list)
					if (SameParams(m, r))
						want = m;
				if (want == null)
					return false;
			}
			if (cur >= 0 && SameParams(list[cur], want))
				return false;
			String why = scope .();
			return Apply(g, call, want, why);
		}

		/// Whether a value of `type` may be wired into the call's argument `pin`: its overload takes
		/// it, or another overload with the same number of arguments does (the wire is made, then
		/// Refit switches to that overload).
		public static bool CouldTake(Graph g, Pin pin, StringView type, TypeService ts)
		{
			if (pin == null || !pin.IsInput || pin.ArgIndex < 0 || pin.IsRefArg)
				return false;
			let call = pin.Owner;
			if (call.Kind != .Call || call.Binding == .Unresolved || ts == null)
				return false;
			List<SymbolMethod> list = scope .();
			ListOf(g, call, ts, list);
			let index = pin.ArgIndex;
			let count = call.ArgCount;
			for (let m in list)
			{
				let pa = ParamsAt(m);
				if (pa >= 0 || m.ParamTypes.Count != count || index >= m.ParamTypes.Count)
					continue;
				if (!Applicable(call, m, null))
					continue;
				if (TypeRules.CanConvert(type, m.ParamTypes[index]) != .Refused)
					return true;
			}
			return false;
		}

		/// A node just made from the Node menu for a wire from a value of `type`: when none of its
		/// inputs takes the value, switch to the overload (same number of arguments) whose input takes
		/// it best. True when the pins changed.
		public static bool FitForValue(Graph g, Node call, StringView type, TypeService ts)
		{
			if (ts == null || call == null || call.Kind != .Call || call.Binding == .Unresolved || TypeRules.IsWildcard(type))
				return false;
			List<Pin> args = scope .();
			call.GetArgPins(args);
			for (let p in args)
				if (p.IsInput && !p.IsRefArg && TypeRules.CanConvert(type, p.TypeName) != .Refused)
					return false;
			List<SymbolMethod> list = scope .();
			ListOf(g, call, ts, list);
			SymbolMethod best = null;
			int bestScore = 0;
			for (let m in list)
			{
				if (ParamsAt(m) >= 0 || m.ParamTypes.Count != args.Count || !Applicable(call, m, null))
					continue;
				for (int i < m.ParamTypes.Count)
				{
					if (IsOutParam(m, i))
						continue;
					int score = 0;
					switch (TypeRules.CanConvert(type, m.ParamTypes[i]))
					{
					case .Exact: score = 8;
					case .Implicit: score = (TypeRules.BaseName(m.ParamTypes[i]) == "Object") ? 3 : 4;
					case .Unchecked: score = 2;
					default:
					}
					if (score > bestScore)
					{
						bestScore = score;
						best = m;
					}
				}
			}
			if (best == null)
				return false;
			String why = scope .();
			return Apply(g, call, best, why);
		}

		// ------------------------------------------------------------------ switching

		/// Whether the node can show overload `m`: its `out` parameters must sit where the node has
		/// out pins (an out pin is not made or turned into an input here).
		public static bool Applicable(Node call, SymbolMethod m, String outWhy)
		{
			List<Pin> args = scope .();
			call.GetArgPins(args);
			let pa = ParamsAt(m);
			int fixedCount = (pa >= 0) ? pa : m.ParamTypes.Count;
			for (int i < fixedCount)
			{
				bool isOut = IsOutParam(m, i);
				bool hasOut = i < args.Count && args[i].IsOutArg;
				if (isOut != hasOut)
				{
					outWhy?.Set("It has out parameters where this node has inputs (or the other way round): change it in the text.");
					return false;
				}
			}
			for (int i = fixedCount; i < args.Count; i++)
			{
				if (args[i].IsOutArg)
				{
					outWhy?.Set("This node has out pins the overload does not have: change it in the text.");
					return false;
				}
			}
			return true;
		}

		/// Makes the node show overload `m`: the argument pins take its names (friendly labels for
		/// the print functions), types and `ref`; pins it does not have are removed, pins it adds
		/// are new inputs (with the parameter's default). A wire stays where its type still fits the
		/// new parameter; a typed value stays when it is still a plain value of the new type, is
		/// carried over when the new type's field can hold it (`2` to `2f`), and is cleared
		/// otherwise; an expression stays as written. False (with the reason) when the node cannot
		/// show it (Applicable).
		public static bool Apply(Graph g, Node call, SymbolMethod m, String outWhy)
		{
			if (!Applicable(call, m, outWhy))
				return false;
			List<Pin> args = scope .();
			call.GetArgPins(args);
			let pa = ParamsAt(m);
			int fixedCount = (pa >= 0) ? pa : m.ParamTypes.Count;
			int newCount = (pa >= 0) ? Math.Max(fixedCount, args.Count) : fixedCount;
			StringView owner = (call.OwnerType != null) ? (StringView)call.OwnerType : (StringView)m.OwnerType;
			for (int i = args.Count - 1; i >= newCount; i--)
				g.RemovePin(args[i]);
			String label = scope .();
			for (int i < fixedCount)
			{
				FriendlyLabel(owner, m.Name, m.ParamNames[i], m.ParamTypes.Count, label);
				StringView mod = (i < m.ParamModifiers.Count) ? (StringView)m.ParamModifiers[i] : "";
				if (i < args.Count)
				{
					Retype(g, args[i], m.ParamTypes[i], label, mod);
					continue;
				}
				let p = g.AddDataIn(call, scope $"arg{i}", label);
				p.TypeName.Set(m.ParamTypes[i]);
				if (mod == "ref")
					p.Mode = .Ref;
				let def = (i < m.ParamDefaults.Count) ? (StringView)m.ParamDefaults[i] : "";
				if (!def.IsEmpty)
					p.Default.Set(def);
				else if (p.TypeName == "bool" && mod.IsEmpty)
					p.Default.Set("false");
			}
			call.Edited = true;
			g.Version++;
			return true;
		}

		static void Retype(Graph g, Pin pin, StringView type, StringView label, StringView mod)
		{
			String oldType = scope .(pin.TypeName);
			pin.Label.Set(label);
			if (pin.IsOutArg)
			{
				pin.TypeName.Set(type);
				return;
			}
			if (pin.WildcardType != null)
				DeleteAndNullify!(pin.WildcardType);
			pin.TypeName.Set(type);
			pin.Mode = (mod == "ref") ? .Ref : .Value;
			let link = g.FindLinkTo(pin);
			if (link != null)
			{
				if (TypeRules.CanConvert(link.From.TypeName, type) == .Refused)
					g.Disconnect(link);
				else
					Graph.UnifyWildcards(link.From, pin);
				return;
			}
			if (pin.Default.IsEmpty || SameType(oldType, type))
				return;
			let ts = TypeService.Current;
			let newKind = PinValue.KindOf(type, pin.Default, pin.Name, ts);
			if (newKind == .Number)
			{
				// A number keeps its value but is written for the new type (`2` -> `2f`): the literal's
				// own type is what makes Beef choose the overload.
				String litType = scope .();
				TypeRules.LiteralType(pin.Default, litType);
				if (SameType(litType, type))
					return;
				String shownNum = scope .();
				PinValue.Display(.Number, oldType, pin.Default, shownNum);
				String litNum = scope .();
				String whyNum = scope .();
				if (PinValue.Write(.Number, type, shownNum, true, litNum, whyNum) && !litNum.IsEmpty)
					pin.Default.Set(litNum);
				return;
			}
			if (newKind != .Custom)
				return; // still a plain value of the new type
			let oldKind = PinValue.KindOf(oldType, pin.Default, pin.Name, ts);
			let fieldKind = PinValue.KindOf(type, "", pin.Name, ts);
			bool oldTyped = oldKind == .Text || oldKind == .Number || oldKind == .Char || oldKind == .Bool || oldKind == .Enum;
			bool newTyped = fieldKind == .Text || fieldKind == .Number || fieldKind == .Char || fieldKind == .Bool || fieldKind == .Enum;
			if (!oldTyped || !newTyped)
				return; // an expression (or a value for a class): kept as written
			String shown = scope .();
			PinValue.Display(oldKind, oldType, pin.Default, shown);
			String lit = scope .();
			String why = scope .();
			bool ok = false;
			if (fieldKind == .Enum)
			{
				List<String> members = scope .();
				defer { ClearAndDeleteItems!(members); }
				PinValue.Members(type, ts, members);
				for (let mm in members)
					if (mm == shown)
						ok = true;
				if (ok)
					lit.AppendF(".{}", shown);
			}
			else if (fieldKind == .Bool)
			{
				ok = shown == "true" || shown == "false";
				if (ok)
					lit.Set(shown);
			}
			else
				ok = PinValue.Write(fieldKind, type, shown, true, lit, why);
			if (ok)
				pin.Default.Set(lit);
			else
				pin.Default.Clear();
		}

		/// The overload chosen in Properties: the node shows it (Apply), and when the arguments as
		/// they are would make Beef call another overload, a Cast to the chosen parameter type is put
		/// on the argument that tells them apart. False (with the reason) when the node cannot show
		/// it; `outNote` says when the code could not be made to call it.
		public static bool Choose(Graph g, Node call, SymbolMethod m, TypeService ts, String outWhy)
		{
			if (!Apply(g, call, m, outWhy))
				return false;
			let r = Resolve(g, call, ts);
			if (r == null || SameParams(r, m))
				return true;
			String pick = scope .();
			Signature(m, pick);
			String other = scope .();
			Signature(r, other);
			let saved = call.Overloads;
			call.Overloads = new .();
			call.Overloads.Add(new String(pick));
			call.Overloads.Add(new String(other));
			String why = scope .();
			let picked = NodeFactory.PickOverload(g, call, pick, why);
			DeleteContainerAndItems!(call.Overloads);
			call.Overloads = saved;
			// PickOverload labels the pins with the parameter names; keep the friendly ones.
			List<Pin> args = scope .();
			call.GetArgPins(args);
			StringView owner = (call.OwnerType != null) ? (StringView)call.OwnerType : (StringView)m.OwnerType;
			String label = scope .();
			for (int i < Math.Min(args.Count, m.ParamNames.Count))
			{
				FriendlyLabel(owner, m.Name, m.ParamNames[i], m.ParamTypes.Count, label);
				args[i].Label.Set(label);
			}
			if (!picked)
				outWhy.Set(why);
			return true;
		}
	}
}
