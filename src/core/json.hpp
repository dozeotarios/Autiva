// Minimal, dependency-free JSON for the SBTouch command protocol.
//
// Why hand-rolled: the dylib is injected into backboardd on a memory-tight
// iPhone X and is built by the device's own clang (Procursus clang-16). Pulling
// a JSON library in for ~10 flat fields would add build and memory surface for
// no gain, and the previous implementation parsed JSON with ad-hoc string
// searching ("find the key, skip a colon, read digits"), which is how you get a
// command that "succeeds" while parsing the wrong value.
//
// Design rules:
//   * no exceptions (the dylib is built -fno-exceptions; a bad_alloc inside
//     backboardd is an abort, i.e. the panic class we are trying to avoid),
//   * no std::to_chars for doubles (absent in the phone's libc++),
//   * parse errors are reported, never guessed around.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace autiva::json {

enum class Type : std::uint8_t { Null, Bool, Number, String, Array, Object };

struct Value {
    Type type = Type::Null;
    bool boolean = false;
    double number = 0.0;
    std::string string;
    std::vector<Value> array;
    std::vector<std::pair<std::string, Value>> object;  // insertion order kept

    bool is_object() const { return type == Type::Object; }
    bool is_array() const { return type == Type::Array; }
    bool is_string() const { return type == Type::String; }
    bool is_number() const { return type == Type::Number; }
};

// Parse one complete JSON value. Returns false and fills `err` on any malformed
// input; `out` is left in an unspecified state and must not be used.
bool parse(std::string_view text, Value& out, std::string& err);

// Serialise a value. Object keys keep insertion order.
std::string dump(const Value& v);

// Object member lookup (nullptr when absent or when `obj` is not an object).
const Value* find(const Value& obj, std::string_view key);

// Convenience readers: each returns false when the key is absent or the wrong
// type, so callers can validate every field they use.
bool get_string(const Value& obj, std::string_view key, std::string& out);
bool get_int(const Value& obj, std::string_view key, long long& out);
bool get_double(const Value& obj, std::string_view key, double& out);
bool get_bool(const Value& obj, std::string_view key, bool& out);

// Escape a string for embedding in JSON (also used for log-safe user input).
std::string escape(std::string_view s);

}  // namespace autiva::json
