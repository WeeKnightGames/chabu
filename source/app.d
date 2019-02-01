import std.algorithm : endsWith;
import std.algorithm.iteration;
import std.array;
import std.conv : to;
import std.datetime;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.uni : toLower;

import docopt : docopt;
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
  if ("classes" in root) {
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

//auto execute(const string[] args, const string work_dir = null) {
//  return std.process.execute(args, null, Config.none, size_t.max, work_dir);
//}

class ExeFailed : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__)
  pure nothrow @nogc @safe {
    super(msg, file, line);
  }
}

auto exe(const string[] args, const string work_dir = null) {
  args.join(" ").writeln;
  auto r = std.process.execute(args, null, Config.none, size_t.max, work_dir);
  if (r.status != 0) {
    throw new ExeFailed("'" ~ args.join(" ") ~ "' failed:\n" ~ r.output);
  } else {
    r.output.write;
  }
  return r;
}

int main(string[] args) {
  auto doc = `chabu - character builder library and tools

  usage:
    chabu new <game> [--title <title>] [--email <email>] [--url <url>] [--license <license>]
    chabu gen [<path>]
    chabu -h|--help
    chabu --version

  options:
    -h|--help               show this screen
    --version               show version
    --title <title>         title of the game [default: A Chabu Game]
    --email <email>         owner's email address [default: wee.knight.games@gmail.com]
    --url <url>             game's base URL [default: https://weeknightgames.github.io/]
    --license <license>     game's license [default: OGL]
    <path>                  path to operate from [default: "."]
`;

  auto arguments = docopt(doc, args[1..$], true, "chabu 0.0.1");
  //writeln(arguments);

  try {
    if (arguments["new"].isTrue) {
      auto name = arguments["<game>"].toString;
      auto title = arguments["--title"].toString;
      auto email = arguments["--email"].toString;
      auto url = arguments["--url"].toString;
      auto license = arguments["--license"].toString;
      auto site = name ~ "/site";

      ("creating new chabu game: " ~ name).writeln;
      exe(["git", "init", name]);
      exe(["hugo", "new", "site", "site"], name);
      exe(["git", "config", "user.email", email], name);
      exe(["git", "commit", "--allow-empty", "-m", "Initializing master branch"], name);

      exe(["git", "checkout", "--orphan", "gh-pages"], name);
      exe(["git", "reset", "--hard"], name);
      exe(["git", "commit", "--allow-empty", "-m", "Initializing gh-pages branch"], name);
      //exe(["git", "push", "origin", "gh-pages"], name);
      exe(["git", "checkout", "master"], name);

      exe(["git", "submodule", "add",
        "https://github.com/jsnjack/kraiklyn.git", "themes/kraiklyn"], site);

      (site ~ "/layouts/partials").mkdirRecurse;
      File(site ~ "/layouts/partials/logo.html", "w");
      File(name ~ "/.gitignore", "w").rawWrite(`/public/
`);

      Mustache mustache;
      mustache.path = "templates";
      auto context = new Mustache.Context;
      context["name"] = name;
      context["title"] = title;
      context["email"] = email;
      context["url"] = url;
      context["license"] = license;
      File(site ~ "/config.toml", "w")
        .rawWrite(mustache.render("config.toml", context));

      (name ~ "/templates/").mkdirRecurse;
      "templates/license.mustache".copy(name ~ "/templates/license.mustache");
      "templates/getting-started.mustache".copy(name ~ "/templates/getting-started.mustache");

      //exe(["git", "add", "."], name);
      //exe(["git", "commit", "-m", "Initial commit."], name);

      exe(["git", "remote", "add", "origin", "https://github.com/WeeKnightGames/" ~ name ~ ".git"], name);
      //exe(["git", "push", "--set-upstream-to", "origin", "master"], name);

      //exe(["git", "worktree", "add", "-B", "gh-pages", "public", "origin/gh-pages"], name);
      exe(["git", "worktree", "add", "-B", "gh-pages", "public", "gh-pages"], name);

      //exe(["git", "init", "rules"], name);
      auto rules = name ~ "/rules";
      rules.mkdirRecurse;

      //exe(["git", "config", "user.email", email], rules);

      File(rules ~ "/base.chabu.yaml", "w")
        .rawWrite(mustache.render("base.chabu.yaml", context));
      File(rules ~ "/license-" ~ license ~ ".chabu.yaml", "w")
        .rawWrite(mustache.render("license-" ~ license ~ ".chabu.yaml", context));

      exe(["git", "add", "."], name);
      exe(["git", "commit", "-m", "Initial commit."], name);
    } else if ("gen" in arguments) {
      auto path = ".";
      if (arguments["<path>"] !is null) {
        path = arguments["<path>"].toString;
      }
      path.writeln;
      auto rules = path ~ "/rules", templates = path ~ "/templates";
      auto base = rules ~ "/base.chabu.yaml";
      auto content = path ~ "/site/content/";
      if (base.exists) {
        base.writeln;
        auto db = base.loadAll;
        auto json = db.toJSON;
        json = json.addAnchors.canonize;
        //json.toPrettyString.writeln;

        Mustache mustache;
        mustache.path = templates;
        foreach (string k, elt; json) {
          //k.writeln;
          if ((mustache.path ~ "/" ~ k ~ ".mustache").exists) {
            (content ~ k).mkdirRecurse;
            auto f = File(content ~ k ~ "/_index.md", "w");
            f.rawWrite(mustache.render(k, json.toMustacheContext));
          } else {
            //(mustache.path ~ "/" ~ k ~ ".mustache does not exist").writeln;
          }
          if ((mustache.path ~ "/" ~ k ~ "-item.mustache").exists) {
            (content ~ k).mkdirRecurse;
            foreach (uint i, item; elt) {
              auto f = File(content ~ k ~ "/" ~ item["name"].str.toLower ~ ".md", "w");
              f.rawWrite(mustache.render(k ~ "-item", item.toMustacheContext));
            }
          } else {
            //(mustache.path ~ "/" ~ k ~ "-item.mustache does not exist").writeln;
          }
        }
      } else {
        (base ~ " does not exist").writeln;
        return 1;
      }
    }
  } catch (ExeFailed ex) {
    ex.message.write;
    return 1;
  }


  //if (args.length > 1) {
  //  auto file = args[1];
  //  if (file.endsWith(".yaml")) {
  //    auto db = file.loadAll;
  //    //db.dump;

  //    auto json = db.toJSON;
  //    //json.toPrettyString.writeln;
  //    json = json.addAnchors.canonize;
  //    //json.toPrettyString.writeln;

  //    string content_root = "/WeeKnightGames/fourth-world-srd/content/";

  //    Mustache mustache;
  //    mustache.path  = "templates";
  //    foreach (string k, elt; json) {
  //      if ((mustache.path ~ "/" ~ k ~ ".mustache").exists) {
  //        (content_root ~ k).mkdirRecurse;
  //        auto f = File(content_root ~ k ~ "/_index.md", "w");
  //        f.rawWrite(mustache.render(k, json.toMustacheContext));
  //      }
  //      if ((mustache.path ~ "/" ~ k ~ "-item.mustache").exists) {
  //        (content_root ~ k).mkdirRecurse;
  //        foreach (uint i, item; elt) {
  //          auto f = File(content_root ~ k ~ "/" ~ item["name"].str.toLower ~ ".md", "w");
  //          f.rawWrite(mustache.render(k ~ "-item", item.toMustacheContext));
  //        }
  //      }
  //    }
  //  } else {
  //    stderr.writeln("usage: chabu [filename]");
  //  }
  //} else {
  //  stderr.writeln("usage: chabu [filename]");
  //}

  return 0;
}
