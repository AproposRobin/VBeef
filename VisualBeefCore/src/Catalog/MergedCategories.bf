using System;
using System.Collections;

namespace VisualBeef.Catalog
{
	/// One row of the Node menu's category tree. Every namespace segment is ONE row per parent:
	/// "System | IO" and "System | Collections" are two children of a single "System" row, however
	/// many sources (corlib, an SDK, the project) contributed them or in which order they arrive.
	/// A row is identified by its full path, never by its name alone.
	class MergedCategory
	{
		public String Name = new .() ~ delete _;
		/// Full path, segments joined with '|' (unique across the tree).
		public String Path = new .() ~ delete _;
		public List<MergedCategory> Children = new .() ~ DeleteContainerAndItems!(_);
		/// The category strings (as the catalog spells them) whose items belong directly to this row.
		public List<String> Cats = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, MergedCategory> mByName = new .() ~ delete _;

		public MergedCategory Child(StringView name)
		{
			if (mByName.TryGetValueAlt(name, let found))
				return found;
			let n = new MergedCategory();
			n.Name.Set(name);
			if (!Path.IsEmpty)
				n.Path.AppendF("{}|", Path);
			n.Path.Append(name);
			Children.Add(n);
			mByName[n.Name] = n;
			return n;
		}

		/// Builds the tree from category strings ("A | B" is B inside A), siblings in first-appearance order.
		public static MergedCategory Build(List<String> cats)
		{
			let root = new MergedCategory();
			for (let cat in cats)
			{
				var node = root;
				for (var part in cat.Split('|'))
				{
					part.Trim();
					if (part.IsEmpty)
						continue;
					node = node.Child(part);
				}
				if (node != root && !node.HasCat(cat))
					node.Cats.Add(new String(cat));
			}
			return root;
		}

		public bool HasCat(StringView cat)
		{
			for (let c in Cats)
				if (c == cat)
					return true;
			return false;
		}

		/// Every Path in the tree (for tests: they must all be distinct).
		public void CollectPaths(List<String> into)
		{
			for (let c in Children)
			{
				into.Add(c.Path);
				c.CollectPaths(into);
			}
		}
	}
}
