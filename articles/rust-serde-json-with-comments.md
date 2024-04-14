---
title: "Rust: serde 互換の JSON with comments パーサーを作ってみた"
emoji: "😽"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["rust", "serde", "jsonc"]
published: true
---

# 作ったもの
https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md#json-with-comments

完成はしていないですが、一旦まともに使うことができるぐらいにはなってきたので、やったことを残すべくこの記事に書いていきます

なお、まだやれてないことも書いておくと↓のような感じです
- パフォーマンスのチューニング、ベンチマークテスト
- raw_value などの serde_json にあるような feature の実装
- commentをパースしてデシリアライズできるようにする(serdeの制限であまり現実的でないかもしれない)

# 使い方
使い方はおよそREADMEに書いてある通りですが、 [serde_json](https://github.com/serde-rs/json) とだいたい同じように使えます。
(まだ実装できてない機能もいくつかあり、また、互換性を持たせることが目的ではないので細かいインターフェースもところどころ異なります)
```toml:Cargo.toml
[dependencies]
json_with_comments = { git = "https://github.com/hayas1/json-with-comments" }
```

## `Deserialize` を実装している型へのデシリアライズ
https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md#parse-jsonc-as-typed-struct

JSONC からのデシリアライズはこんな感じです。コメントがついていたり trailing comma があったりしてもパースできる以外はだいたい serde_json と同じですね
```rust
use serde::Deserialize;
#[derive(Deserialize)]
struct Person<'a> {
    name: &'a str,
    address: Address<'a>,
}
#[derive(Deserialize)]
struct Address<'a> {
    street: &'a str,
    number: u32,
}

let json = r#"{
    "name": "John Doe", // John Doe is a fictional character
    "address": {
        "street": "Main",
        "number": 42, /* trailing comma */
    },
}"#;

let data: Person = json_with_comments::from_str(json).unwrap();
assert!(matches!(
    data,
    Person {
        name: "John Doe",
        address: Address { street: "Main", number: 42 }
    }
));
```

## `Value` 構造体へのデシリアライズ
JSONCをデシリアライズしたい型が決まってない時は `Value` 構造体を使うことができます。 `Value` 構造体は `[]` を使ってインデックスアクセスができたり、その他いくつか便利なメソッドを持っています。 `jsonc!` マクロを使って `Value` を作ることもできます。このあたりも serde_json とだいたい同じですね。
```rust
use json_with_comments::{from_str, Value, jsonc};

let json = r#"{
    "name": "John Doe", // John Doe is a fictional character
    "address": {
        "street": "Main",
        "number": 42, /* trailing comma */
    },
}"#;

let data: Value = from_str(json).unwrap();
assert_eq!(data["name"], Value::String("John Doe".into()));
assert_eq!(data["address"]["street"], Value::String("Main".into()));
assert_eq!(data.query("address.number"), Some(&42.into()));
assert_eq!(data, jsonc!({ "name": "John Doe", "address": { "street": "Main", "number": 42 }}));
```

## `Serialize` を実装している型からのシリアライズ
データを JSONC へシリアライズすることもできます。これも serde_json とだいたい同じですね
```rust
use serde::Serialize;
#[derive(Serialize)]
struct Person<'a> {
    name: &'a str,
    address: Address<'a>,
}
#[derive(Serialize)]
struct Address<'a> {
    street: &'a str,
    number: u32,
}

let person = Person {
    name: "John Doe",
    address: Address {
        street: "Main",
        number: 42,
    },
};

let minify = r#"{"name":"John Doe","address":{"street":"Main","number":42}}"#;
assert_eq!(json_with_comments::to_string(&person).unwrap(), minify);

let pretty = r#"{
  "name": "John Doe",
  "address": {
    "street": "Main",
    "number": 42,
  },
}"#;
assert_eq!(json_with_comments::to_string_pretty(&person).unwrap(), pretty);
```

## serde_json の `Value` 構造体との相互変換
さらに、 `Value` 構造体を、 `Serialize` や `Deserialize` を実装している構造体へシリアライズしたりデシリアライズしたりすることもできます。実はこれも serde_json とだいたい同じです。今回はこれを使って、 `json_with_comments::Value` と `serde_json::Value` の相互変換を実現しています。
```rust
use serde::{Deserialize, Serialize};
use serde_json::json;
use json_with_comments::jsonc;

let (json, jsonc) = (json!({"name": "John Doe","age": 30}), jsonc!({ "name": "John Doe", "age": 30 }));

// serde_json::Value -> json_with_comments::Value
assert_eq!(json_with_comments::to_value(&json).unwrap(), jsonc);
assert_eq!(serde_json::from_value::<json_with_comments::Value>(json.clone()).unwrap(), jsonc);

// json_with_comments::Value -> serde_json::Value
assert_eq!(json_with_comments::from_value::<serde_json::Value>(&jsonc).unwrap(), json);
assert_eq!(serde_json::to_value(jsonc.clone()).unwrap(), json);
```


# やったこと
それぞれまた別でフォーカスを当てて別の記事に起こしてみようかとも思っていますが、↓のようなことをやっています。

## serde の抽象化に従う
### Deserialize
serde において Deserialize の登場人物は大きく 3 人です。
- `Deserialize` トレイト: `Deserializer` トレイトによってデシリアライズできる型のことです。ほぼマーカーみたいなものです。
- `Deserializer` トレイト: 実際にデシリアライズする人のことです。パーサーみたいなものです。
- `Visitor` トレイト: パースされた値を実際にRustの値として対応させる人です。
  - 例えば `100` という JSON を `usize` にデシリアライズしたいとして、`usize`の変数に実際に値を代入する部分をやっているイメージです

つまり、今回実装していくのは `Deserializer` トレイトが主軸になるということです。 `Deserializer` トレイトはかなりたくさんのメソッドを要求していて、たとえば `deserialize_any` や `deserialize_bool` があります。ちなみに、これらのメソッドが引数として `Visitor` をもらっている、いわゆる Visitor パターンになっています。`deserialize_bool` は今読んでいる文字列が `true` であれば `true` を、 `false` であれば `false` を、 `Visitor` に渡せばいいだけなので実装が比較的楽です。一方で `deserialize_any` などはそうもいかず、例えば今読んでいる文字列が `{` であれば Object(いわゆる Map) のパースが必要です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L58-L91

↑に載せた実装の  `deserialize_any` では今読んでいる文字列が `{` だったときは `Deserializer` トレイトで同じく要求されている `deserialize_map` メソッドを呼んでいます。 `deserialize_map` メソッドでは↓のように、 `{` の中身のパースを `MapDeserializer` 構造体に任せており、これは serde の `MapAccess` トレイトを実装したものになっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L276-L290

`MapAccess` トレイトが要求しているメソッドは幸い(？) 2 つだけで、 `next_key_seed` と `next_value_seed` だけです。 `next_key_seed` が `None` を返せば Map は終わりという、 Iterator のようなインターフェースを備えています。 `next_value_seed` では、またまた JSON が入れ子になる可能性がありますが、それに関しての実装は実は簡単で、上で今まで作ってきたような `Deserializer` に処理を投げればよいです。逆にkeyの方が(JSONでは文字列だけという制限があるため)今まで作った `Deserializer` にまるまる処理を投げることができずむしろ大変です(専用の `Deserializer` を用意しています…)。それさえ済めば、あとは `:` による key と value の区切りや、 `,` による key-value の区切り、 `}` による Object の終わりなどを処理すればよいぐらいです。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/map.rs#L26-L59

↑では Object の入れ子の処理について書きましたが、 Array についても似たような実装をやっていく必要があります。また、各種の数値型や struct や enum のデシリアライズについても実装していく必要があったり、ここでは触れませんがなかなか多くのコードが必要になってきます。

### Serialize
serde において Serialize は Visitor パターンではないので、登場人物は大きく 2 人と言って差し支えないと思います。こっちは Deserialize よりはシンプルです。
- `Serialize` トレイト: `Serializer` トレイトによってシリアライズできる型のことです。
  - `Deserialize` トレイトと同じくほぼマーカーみたいなものです。
- `Serializer` トレイト: 実際にシリアライズをやる人のことです。
  - `SerializeSeq` や `SerializeMap` などのトレイトに、入れ子部分のシリアライズを任せたりはしています。

Serialize についても Deserialize と同じく、今回実装していくのは `Serializer` トレイトが主軸になります。このトレイトは、 `SerializeMap` などの入れ子をシリアライズする型を Associated Type でたくさん要求していて、`serialize_bool` や `serialize_map` などこちらもたくさんのメソッドを要求しています。 `Serializer` については特に Visitor パターンという感じでもなく、各メソッドがそれぞれ実際の値を渡されるので、それを文字列にしていく処理をゴソゴソと書いていく形です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L25-L54

`serialize_map` などのメソッドでは、処理を `SerializeMap` に投げています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L172-L174

`SerializeMap` のやることも、 Deserialize の `MapAccess` 同様です。value部分の入れ子をおおもとの `Serializer` に投げたり、key部分には専用の `Serializer` を用意したりします。`:` による key と value の区切り、 `,` による key-value の区切り、 `}` による Object の終わりなどを文字列として書き込んでいきます(↓のコードでは、minify format の JSON と pretty format の JSON どちらにも出力できるための抽象化が入っているのでリテラルとして `:` や `,` や `}` が直接ここのコードに現れてはないですが)。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/map.rs#L27-L58

Serialize は Deserialize よりシンプルではありますが、入れ子を処理するためのトレイトが、`SerializeSeq`, `SerializeTuple`, `SerializeTupleStruct`, `SerializeTupleVariant`, `SerializeMap`, `SerializeStruct`, `SerializeStructVariant` の 7 個ほどあったりするので、なんだかんだで Deserialize と同じくらいの量のコードを書くことになります。(`SerializeTuple` の処理は実質 `SerializeSeq` に投げれたりということもあって全部が全部実装を書いていかないといけないわけではない)

## `Value` の Serialize と Deserialize
文字列 ↔ Rustの値 だけでなく、 `Value` ↔ Rustの値 についても Serialize と Deserialize で抽象化されるため、その実装もあります。

## macro の実装
munch

## コードの共通化
traitを使って、同じようなコードを書かないようにする工夫

## CI で楽をする
単体テスト、カバレッジ、ドキュメント生成、ドキュメントの追従漏れチェック、リリース作成
GitHub Pages


# 感想
serdeが提供する抽象化に沿ってコードを書いていけばいい感じのパーサーを作ることができてすごいです。
一方で、記述量はその分なかなか多くなります。自分で工夫できる領域も少なくなるのでちょっと物足りない部分もあります。


