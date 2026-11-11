#include "json.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace autiva::json {
namespace {

constexpr int kMaxDepth = 16;  // a system daemon must not recurse without bound

struct Parser {
    std::string_view in;
    std::size_t i = 0;
    std::string err;

    bool eof() const { return i >= in.size(); }
    char peek() const { return i < in.size() ? in[i] : '\0'; }

    void skip_ws() {
        while (i < in.size()) {
            const char c = in[i];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++i;
            } else {
                break;
            }
        }
    }

    bool fail(const char* what) {
        if (err.empty()) {
            char buf[128];
            std::snprintf(buf, sizeof buf, "%s at byte %zu", what, i);
            err = buf;
        }
        return false;
    }

    static void append_utf8(std::string& out, unsigned cp) {
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool parse_hex4(unsigned& out) {
        if (i + 4 > in.size()) return fail("short \\u escape");
        unsigned v = 0;
        for (int n = 0; n < 4; ++n) {
            const char c = in[i++];
            v <<= 4;
            if (c >= '0' && c <= '9') {
                v |= static_cast<unsigned>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                v |= static_cast<unsigned>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                v |= static_cast<unsigned>(c - 'A' + 10);
            } else {
                return fail("bad hex digit in \\u escape");
            }
        }
        out = v;
        return true;
    }

    bool parse_string(std::string& out) {
        if (peek() != '"') return fail("expected string");
        ++i;
        out.clear();
        while (true) {
            if (eof()) return fail("unterminated string");
            const char c = in[i++];
            if (c == '"') return true;
            if (c != '\\') {
                if (static_cast<unsigned char>(c) < 0x20) return fail("control byte in string");
                out.push_back(c);
                continue;
            }
            if (eof()) return fail("trailing backslash");
            const char e = in[i++];
            switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned cp = 0;
                    if (!parse_hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        // Surrogate pair: \uD83D\uDE00
                        if (i + 1 < in.size() && in[i] == '\\' && in[i + 1] == 'u') {
                            i += 2;
                            unsigned lo = 0;
                            if (!parse_hex4(lo)) return false;
                            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            } else {
                                return fail("bad low surrogate");
                            }
                        } else {
                            return fail("lone high surrogate");
                        }
                    }
                    append_utf8(out, cp);
                    break;
                }
                default: return fail("unknown escape");
            }
        }
    }

    bool parse_number(Value& out) {
        const std::size_t start = i;
        if (peek() == '-') ++i;
        // Strict JSON: no leading zeros ("01" is not a number). Being strict
        // here is deliberate — the host is the only producer, and a lenient
        // reader hides producer bugs instead of reporting them.
        if (peek() == '0' && i + 1 < in.size() && in[i + 1] >= '0' && in[i + 1] <= '9') {
            return fail("leading zero in number");
        }
        while (i < in.size() && in[i] >= '0' && in[i] <= '9') ++i;
        if (peek() == '.') {
            ++i;
            while (i < in.size() && in[i] >= '0' && in[i] <= '9') ++i;
        }
        if (peek() == 'e' || peek() == 'E') {
            ++i;
            if (peek() == '+' || peek() == '-') ++i;
            while (i < in.size() && in[i] >= '0' && in[i] <= '9') ++i;
        }
        if (i == start) return fail("expected number");
        // strtod needs a terminator; the span is short (<= 32 bytes).
        char buf[48];
        const std::size_t n = i - start;
        if (n >= sizeof buf) return fail("number too long");
        std::memcpy(buf, in.data() + start, n);
        buf[n] = '\0';
        char* end = nullptr;
        const double v = std::strtod(buf, &end);
        if (end != buf + n) return fail("malformed number");
        out.type = Type::Number;
        out.number = v;
        return true;
    }

    bool parse_value(Value& out, int depth) {
        if (depth > kMaxDepth) return fail("nesting too deep");
        skip_ws();
        if (eof()) return fail("unexpected end of input");
        const char c = peek();
        if (c == '{') {
            ++i;
            out.type = Type::Object;
            skip_ws();
            if (peek() == '}') {
                ++i;
                return true;
            }
            while (true) {
                skip_ws();
                std::string key;
                if (!parse_string(key)) return false;
                skip_ws();
                if (peek() != ':') return fail("expected ':'");
                ++i;
                Value member;
                if (!parse_value(member, depth + 1)) return false;
                out.object.emplace_back(std::move(key), std::move(member));
                skip_ws();
                if (peek() == ',') {
                    ++i;
                    continue;
                }
                if (peek() == '}') {
                    ++i;
                    return true;
                }
                return fail("expected ',' or '}'");
            }
        }
        if (c == '[') {
            ++i;
            out.type = Type::Array;
            skip_ws();
            if (peek() == ']') {
                ++i;
                return true;
            }
            while (true) {
                Value element;
                if (!parse_value(element, depth + 1)) return false;
                out.array.push_back(std::move(element));
                skip_ws();
                if (peek() == ',') {
                    ++i;
                    continue;
                }
                if (peek() == ']') {
                    ++i;
                    return true;
                }
                return fail("expected ',' or ']'");
            }
        }
        if (c == '"') {
            out.type = Type::String;
            return parse_string(out.string);
        }
        if (c == 't' && in.substr(i, 4) == "true") {
            i += 4;
            out.type = Type::Bool;
            out.boolean = true;
            return true;
        }
        if (c == 'f' && in.substr(i, 5) == "false") {
            i += 5;
            out.type = Type::Bool;
            out.boolean = false;
            return true;
        }
        if (c == 'n' && in.substr(i, 4) == "null") {
            i += 4;
            out.type = Type::Null;
            return true;
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            return parse_number(out);
        }
        return fail("unexpected character");
    }
};

std::string format_number(double v) {
    char buf[48];
    if (!std::isfinite(v)) {
        return "null";  // JSON has no NaN/Inf
    }
    // Integral values print as integers: a coordinate of 562 must not become
    // 562.0000000000001 in a reply another process has to parse.
    if (v == static_cast<double>(static_cast<long long>(v)) && std::fabs(v) < 9.0e15) {
        std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(v));
        return buf;
    }
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

}  // namespace

bool parse(std::string_view text, Value& out, std::string& err) {
    Parser p{text, 0, {}};
    out = Value{};
    if (!p.parse_value(out, 0)) {
        err = p.err.empty() ? "parse error" : p.err;
        return false;
    }
    p.skip_ws();
    if (!p.eof()) {
        err = "trailing data after JSON value";
        return false;
    }
    return true;
}

std::string escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (const char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

std::string dump(const Value& v) {
    switch (v.type) {
        case Type::Null: return "null";
        case Type::Bool: return v.boolean ? "true" : "false";
        case Type::Number: return format_number(v.number);
        case Type::String: return "\"" + escape(v.string) + "\"";
        case Type::Array: {
            std::string out = "[";
            for (std::size_t n = 0; n < v.array.size(); ++n) {
                if (n) out += ',';
                out += dump(v.array[n]);
            }
            out += ']';
            return out;
        }
        case Type::Object: {
            std::string out = "{";
            for (std::size_t n = 0; n < v.object.size(); ++n) {
                if (n) out += ',';
                out += "\"" + escape(v.object[n].first) + "\":" + dump(v.object[n].second);
            }
            out += '}';
            return out;
        }
    }
    return "null";
}

const Value* find(const Value& obj, std::string_view key) {
    if (obj.type != Type::Object) return nullptr;
    for (const auto& kv : obj.object) {
        if (kv.first == key) return &kv.second;
    }
    return nullptr;
}

bool get_string(const Value& obj, std::string_view key, std::string& out) {
    const Value* v = find(obj, key);
    if (!v || v->type != Type::String) return false;
    out = v->string;
    return true;
}

bool get_double(const Value& obj, std::string_view key, double& out) {
    const Value* v = find(obj, key);
    if (!v || v->type != Type::Number) return false;
    out = v->number;
    return true;
}

bool get_int(const Value& obj, std::string_view key, long long& out) {
    double d = 0.0;
    if (!get_double(obj, key, d)) return false;
    out = static_cast<long long>(d);
    return true;
}

bool get_bool(const Value& obj, std::string_view key, bool& out) {
    const Value* v = find(obj, key);
    if (!v || v->type != Type::Bool) return false;
    out = v->boolean;
    return true;
}

}  // namespace autiva::json
