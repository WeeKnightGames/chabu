import std.algorithm : endsWith;
import std.algorithm.iteration;
import std.array;
import std.conv : to;
import std.datetime;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.uni : toLower;

import dyaml;
import mustache;
alias Mustache = MustacheEngine!(string);

auto load1(string file) {
  return Loader.fromFile(file).load;
}

auto loadN(string[] files) {
  Node[] nds;
  foreach (file; files) {
    nds ~= file.load1;
  }
  return nds;
}

auto loadN(S...)(S files) {
  Node[] nds;
  foreach (file; files) {
    nds ~= file.to!string.load1;
  }
  return nds;
}

auto dump(Node root) {
  auto dumper = dumper(stdout.lockingTextWriter);
  return dumper.dump(root);
}

Node merge(Node root, Node child) {
  if (root.isSequence && child.isSequence) {
    foreach (Node val; child) {
      root.add(val);
    }
  } else {
    foreach (childkey; child.mappingKeys!string) {
      if (childkey in root) {
        //(childkey ~ " in root").writeln;
        root[childkey] = root[childkey].merge(child[childkey]);
      } else {
        root[childkey] = child[childkey];
      }
    }
  }
  return root;
}

Node loadAll(string file) {
  file = file.absolutePath;
  auto dir = file.dirName;
  auto root = file.load1;
  if ("include" in root) {
    string[] kids = root["include"].sequence!string.array;
    root.removeAt("include");
    auto abskids = kids
      .map!(include => buildPath(dir, include).to!string)
      .array;
    foreach (abskid; abskids) {
      root = root.merge(abskid.loadAll);
    }
  }
  return root;
}

JSONValue toJSON(Node node) {
  JSONValue output;
  if (node.isSequence) {
    output = JSONValue(string[].init);
    foreach (Node seqNode; node) {
      output.array ~= seqNode.toJSON();
    }
  } else if (node.isMapping) {
    output = JSONValue(string[string].init);
    foreach (Node keyNode, Node valueNode; node) {
      output[keyNode.as!string] = valueNode.toJSON();
    }
  } else if (node.isString) {
    output = node.as!string;
  } else if (node.isInt) {
    output = node.as!long;
  } else if (node.isFloat) {
    output = node.as!real;
  } else if (node.isBool) {
    output = node.as!bool;
  } else if (node.isTime) {
    output = node.as!SysTime.toISOExtString();
  }
  return output;
}

bool isObject(ref JSONValue node) @property {
  return node.type == JSON_TYPE.OBJECT;
}
bool isArray(ref JSONValue node) @property {
  return node.type == JSON_TYPE.ARRAY;
}
bool isString(ref JSONValue node) @property {
  return node.type == JSON_TYPE.STRING;
}

JSONValue lookup(ref JSONValue node, string needle) {
  if (node.isArray) {
    foreach (uint i, JSONValue elt; node) {
      if (auto name = "name" in elt) {
        if (name.str == needle) {
          return elt;
        }
      }
    }
  }
  return JSONValue();
}

JSONValue addAnchors(ref JSONValue node, string path = "") {
  if (node.isObject) {
    if ("name" in node) {
      node.object["name:anchor"] = path ~ node["name"].str
        .toLower.replace(" ", "-").replace("(", "").replace(")", "");
    }
    foreach (string k, v; node) {
      addAnchors(v, path ~ k ~ "-");
    }
  } else if (node.isArray) {
    foreach (uint k, v; node) {
      addAnchors(v, path);
    }
  }
  return node;
}

JSONValue canonize(JSONValue root) {
  foreach (uint i, ref JSONValue elt; root["classes"]) {
    if ("features" in elt) {
      foreach (uint i, ref JSONValue feature; elt["features"]) {
        if (feature.isString) {
          auto found = root["features"].lookup(feature.str);
          if (found.isNull) {
            ("warning: " ~ feature.str ~ " does not exist").writeln;
          } else {
            feature = found;
          }
        }
      }
    }
  }
  return root;
}

Mustache.Context toMustacheContext(ref JSONValue node, Mustache.Context parent) {
  if (node.isObject) {
    foreach (string k, JSONValue v; node) {
      if (v.isArray) {
        foreach (uint i, JSONValue elt; v) {
          auto sub = parent.addSubContext(k);
          toMustacheContext(elt, sub);
        }
      } else if (v.isObject) {
        auto sub = parent.addSubContext(k);
        toMustacheContext(v, sub);
      } else if (v.isString) {
        parent[k] = v.str;
      } else {
        parent[k] = v.to!string;
      }
    }
  } else if (node.isString) {
    parent["name"] = node.str;
    parent["fluff"] = "";
  }
  return parent;
}

Mustache.Context toMustacheContext(ref JSONValue node) {
  auto context = new Mustache.Context;
  toMustacheContext(node, context);
  return context;
}

void main(string[] args) {
  if (args.length > 1) {
    auto file = args[1];
    if (file.endsWith(".yaml")) {
      auto db = file.loadAll;
      //db.dump;

      auto json = db.toJSON;
      //json.toPrettyString.writeln;
      json = json.addAnchors.canonize;
      //json.toPrettyString.writeln;

      string content_root = "/WeeKnightGames/fourth-world-srd/content/";

      Mustache mustache;
      mustache.path  = "templates";
      foreach (string k, elt; json) {
        if ((mustache.path ~ "/" ~ k ~ ".mustache").exists) {
          (content_root ~ k).mkdirRecurse;
          auto f = File(content_root ~ k ~ "/_index.md", "w");
          f.rawWrite(mustache.render(k, json.toMustacheContext));
        }
        if ((mustache.path ~ "/" ~ k ~ "-item.mustache").exists) {
          (content_root ~ k).mkdirRecurse;
          foreach (uint i, item; elt) {
            auto f = File(content_root ~ k ~ "/" ~ item["name"].str.toLower ~ ".md", "w");
            f.rawWrite(mustache.render(k ~ "-item", item.toMustacheContext));
          }
        }
      }
    } else {
      stderr.writeln("usage: chabu [filename]");
    }
  } else {
    stderr.writeln("usage: chabu [filename]");
  }
}
