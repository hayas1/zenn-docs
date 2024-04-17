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
- raw_value などの serde_json にあるような feature の実装
- パフォーマンスのチューニング、ベンチマークテスト
- commentをパースしてデシリアライズできるようにする(serdeの制限であまり現実的でないかもしれない)

# 使い方
使い方はおよそ README に書いてある通りですが、 [serde_json](https://github.com/serde-rs/json) とだいたい同じように使えます。
(まだ実装できてない機能もいくつかあり、また、互換性を持たせることが目的ではないので細かいインターフェースもところどころ異なります)
```toml:Cargo.toml
[dependencies]
json-with-comments = { git = "https://github.com/hayas1/json-with-comments", tag = "v0.1.5" }
```

## `Deserialize` を実装している型へのデシリアライズ
https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md#parse-jsonc-as-typed-struct

JSONC からのデシリアライズはこんな感じで `from_str` 関数を使います。コメントがついていたり trailing comma があったりしてもパースできる以外はだいたい serde_json と同じですね
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

## `Value` へのデシリアライズ
JSONC をデシリアライズしたい型が決まってない時は `Value` の型を使うことができます。 `Value` は `[]` を使ってインデックスアクセスができたり、その他いくつか便利なメソッドを持っています。 `jsonc!` マクロを使って `Value` を作ることもできます。このあたりも serde_json とだいたい同じです
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
データを JSONC へシリアライズすることもできます。minify な JSONC (つまり JSON と同じ)にする `to_string` 関数と、pretty な JSONC (trailing comma がある)にする `to_string_pretty` 関数の2つがあります。これも serde_json とだいたい同じですね
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

## serde_json の `Value` との相互変換
さらに、`to_value` や `from_value` などの関数を使って、 `Value` を `Serialize` を実装している型からシリアライズしたり、 `Deserialize` を実装している型へデシリアライズしたりすることもできます。実はこれも serde_json とだいたい同じです。今回はこれを使って、 `json_with_comments::Value` と `serde_json::Value` の相互変換を実現しています。詳しくは下でも触れます。
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


# 実装について
実装は serde_json とかなり近く、serde や serde_json のおさらいみたいな感じにもなりますが、せっかくなので書いていきます。

## serde の抽象化に従う
### Deserialize
serde において Deserialize の登場人物は大きく 3 人です。
- `Deserialize` トレイト: `Deserializer` トレイトによってデシリアライズできる型のことです。ほぼマーカーみたいなものです。
- `Deserializer` トレイト: 実際にデシリアライズする人のことです。パーサーみたいなものです。
- `Visitor` トレイト: パースされた値を実際にRustの値として対応させる人です。
  - 例えば `100` という JSON を `usize` にデシリアライズしたいとして、`usize`の変数に実際に値を代入する部分をやっているイメージです

今回実装していくのは `Deserializer` トレイトが主軸になり、あとは serde がよしなにやってくれます。 `Deserializer` トレイトはかなりたくさんのメソッドを要求していて、たとえば `deserialize_any` や `deserialize_bool` があります。ちなみに、これらのメソッドは引数として `Visitor` をもらっている、いわゆる Visitor パターンになっています。`deserialize_bool` は今読んでいる文字列が `true` であれば `true` を、 `false` であれば `false` を、 `Visitor` に渡せばいいだけなので実装が比較的楽です。一方で `deserialize_any` などはそうもいかず、例えば今読んでいる文字列が `{` であれば Object(いわゆる Map) のパースが必要です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L58-L91

↑に載せた実装の  `deserialize_any` では今読んでいる文字列が `{` だったとき(74 行目)は `Deserializer` トレイトで同じく要求されている `deserialize_map` メソッドを呼んでいます。 `deserialize_map` メソッドでは↓のように、 `{` の中身のパースを `MapDeserializer` 構造体に任せており、これは serde の `MapAccess` トレイトを実装したものになっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L276-L290

`MapAccess` トレイトが要求しているメソッドは幸い(？) 2 つだけで、 `next_key_seed` と `next_value_seed` だけです。 `next_key_seed` が `None` を返せば Map は終わりという、 Iterator のようなインターフェースを備えています。 `next_value_seed` では、 JSON が入れ子になる可能性がありますが、それに関しての実装は実は簡単で、上で今まで作ってきたような `Deserializer` に処理を投げればよいです。逆にkeyの方が(JSONでは文字列だけという制限があるため)今まで作った `Deserializer` にまるまる処理を投げることができずむしろ大変です(専用の `Deserializer` を用意しています…)。それさえ済めば、あとは `:` による key と value の区切りや、 `,` による key-value の区切り、 `}` による Object の終わりなどを処理すればよいぐらいです。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/map.rs#L26-L59

↑では Object(いわゆる Map) の入れ子の処理について書きましたが、 Array についても似たような実装をやっていく必要があります。また、各種の数値型や struct や enum のデシリアライズについても実装していく必要があったり、ここでは触れませんがなかなか多くのコードが必要になってきます。

### Serialize
serde において Serialize は Visitor パターンではないので、こっちの登場人物は大きく 2 人と言って差し支えないと思います。Serialize は Deserialize よりはシンプルです。
- `Serialize` トレイト: `Serializer` トレイトによってシリアライズできる型のことです。
  - `Deserialize` トレイトと同じくほぼマーカーみたいなものです。
- `Serializer` トレイト: 実際にシリアライズをやる人のことです。
  - `SerializeSeq` や `SerializeMap` などのトレイトに、入れ子部分のシリアライズを任せたりはしています。

Serialize についても Deserialize と同じく、今回実装していくのは `Serializer` トレイトが主軸になり、あとは serde がよしなにやってくれます。このトレイトは、 `SerializeMap` などの入れ子をシリアライズする型を Associated Type でたくさん要求していて、`serialize_bool` や `serialize_map` などシリアライズ用のメソッドもたくさん要求しています。 `Serializer` については特に Visitor パターンではなく、各メソッドがそれぞれ実際の値を渡されるので、それを文字列にしていく処理をゴソゴソと書いていく形です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L25-L54

bool や数値など、入れ子でないデータ型についてはそのまま文字列にすればよいですが、 Object(いわゆる Map) などの入れ子になりうるデータ型については、入れ子部分の処理もする必要があります。`serialize_map` などのメソッドでは、処理を `SerializeMap` に投げています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L172-L174

`SerializeMap` のやることも、 Deserialize の `MapAccess` 同様です。value部分の入れ子をおおもとの `Serializer` に投げたり、key部分には専用の `Serializer` を用意したりします。`:` による key と value の区切り、 `,` による key-value の区切り、 `}` による Object の終わりなどを文字列として書き込んでいきます(↓のコードでは、minify format の JSON と pretty format の JSON どちらにも出力できるための抽象化が入っているのでリテラルとして `:` や `,` や `}` が直接ここのコードに現れてはないですが)。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/map.rs#L27-L58

Serialize は Deserialize よりシンプルではありますが、入れ子を処理するためのトレイトが、`SerializeSeq`, `SerializeTuple`, `SerializeTupleStruct`, `SerializeTupleVariant`, `SerializeMap`, `SerializeStruct`, `SerializeStructVariant` の 7 個ほどあったりするので、なんだかんだで Deserialize と同じくらいの量のコードを書くことになります。(`SerializeTuple` の処理は実質 `SerializeSeq` に投げれたりということもあって全部が全部実装を書いていかないといけないわけではない)

## `Value` の Serialize と Deserialize
**文字列 ↔ Rust の値** だけでなく、 **`Value` ↔ Rust の値** についても Serialize と Deserialize で抽象化されるため、その実装もあります。はじめに `Value` について書いておくと、これはその実 `Map` や `String` といったJSONの値を表す enum になっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value.rs#L63-L100

つまり、パーサーが「今読んでいる文字列」に応じて Rust の値へデシリアライズするのと同様に、`Value` の「今見ている値」に応じて Rust の値へデシリアライズできます。そして、Rust の値を JSON 文字列にシリアライズできるのと同様に、 Rust の値を `Value` へシリアライズできます。
そのための実装が [value/de](https://github.com/hayas1/json-with-comments/tree/v0.1.5/src/value/de) や [value/ser](https://github.com/hayas1/json-with-comments/tree/v0.1.5/src/value/ser) に書いてあります。

- たとえば、`deserialize_bool` は、**文字列 → Rust の値** で Deserialize するときは `true` か `false` の文字列をパースしようとしましたが、**`Value` → Rust の値** で Deserialize するときは、今見ているのが `Value::Bool` であれば、 `Visitor` に bool を渡し、そうでなければエラーという感じです

https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/de/deserializer.rs#L59-L91

- また、`serialize_bool` だと、**Rust の値 → 文字列** で Serialize するときは `true` か `false` の値をそのまま文字列にしていましたが、**Rust の値 → `Value`** で Serialize するときは、受け取った bool の値に応じて `Value::Bool` を返す感じになります。

https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/ser/serializer.rs#L29-L50

今回作った `json-with-comments` の `Value` と `serde_json` の `Value` で相互変換する仕組みは、これに乗っかっています。

## macro の実装
主にはデシリアライズしたい型が定まっていない場合などに使う `Value` の列挙型ですが、文字列をパースとかしなくても作りたいですよね。
`{"key": "value", "null": null}` みたいな JSON を表現するためにいちいち↓みたいに書いてると大変です。
```rust
let value = Value::Object(HashMap::from([("key".to_string(), Value::String("value".to_string())), ("null".to_string(), Value::Null)]));
```
そのために、 `serde_json` では `Value` を簡単に作ることができる `json!` macro が用意されていて、今回作った `json-with-comments` でも同様に `Value` を簡単に作ることができる `jsonc!` macro を用意しています。↓みたいな感じでお手軽に JSON を表現できます
```rust
let value = jsonc!({"key": "value", "null": null});
```

`jsonc!` マクロは何段階かのマクロから構成されていて、中心部分は↓の `jsonc_generics!` マクロです

https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/macros.rs#L62-L81
Rust の macro (ここでは[宣言的マクロ](https://doc.rust-jp.rs/book-ja/ch19-06-macros.html)のことです) は基本的に引数を解析して `block`, `expr`, `tt` などの[マッチする構造](https://doc.rust-lang.org/reference/macros-by-example.html#metavariables)に応じてコード生成して置き換える、といったことをします。`expr` は式のことで、`tt` はトークンツリーのことです。↑のコードだと、
- `[` `]` で囲われていたら `array!` macro に処理を投げる
- `{` `}` で囲われていたら `object!` macro に処理を投げる
- null だったら `Value::Null` を返す
- `expr` だったら `Value::from` を使って `Value` を生成する

という雰囲気です。 `null` という文字列は Rust 的には式ではないので `expr` にはマッチしないといったミソもあったりします。

実装の中でも、`object!` macro が `array!` macro に比べてもちょっと大変だった話があるので、簡単に紹介します
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/macros.rs#L151-L224

`object!` macro がやりたいことは、以下です。
- `key: value,` の形を見つけて、 `(key, value)` の tuple にする
- `key: value,` の形がなくなるまで繰り返す
- すると、 `[(key, value), ...]` のようなリストが作られるので、 `.into_iter().collect()` して `HashMap` にする

このうち、`key: value` の形を見つける部分がちょっと大変でした。`{$key:expr : $($rest:tt)*}` などで簡単にマッチできそうにも見えますが、これはコンパイラに怒られてしまいます。 `expr` の区切りとして `:` は使えなくて、 `=>` が `,` か `;` だそうです。macro のマッチなどはなかなか仕様が大変そうです。
こんなときにどうするかというと、前から順番に `tt` を一つずつ見て、 `:` が先頭に来るまで取り出していく、といったようなことをします(↑の macros.rs のコード片で言うと、 220 行目あたりです)。先頭に `:` が来ると、他のパターンにマッチして value を取り出す処理が始まります。`:` が来るまで一回一回 `object!` macro を繰り返し呼ぶということなので、ちょっとパフォーマンスに懸念がありますね。まあコンパイル時に行われることなのでよいかなという気もします。
ちなみに、こんな感じで macro で `tt` を1つ1つ取り出すことを、munch と呼ぶそうです。むしゃむしゃ食べるみたいな意味らしいです。

他にも `array!` macro や `object!` macro では trailing comma の処理が色々試してみてもうまくいかず、結局同じような処理を2回書きがちみたいな感じにもなっているので、ちょっと悔いが残る感じの実装になってます。


# CI について
CIもいくつか作ってるので、これについても書いてみます。

## 単体テスト、formatter のチェック、linterのチェック
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L28-L32
`cargo test` とか `cargo fmt --check` とか `cargo clippy` とかをやっているだけではあります。
自動フォーマットとかは CI ではしておらず、CIがこけるみたいな感じになっています。 CI に勝手にコミットされるのがうれしくないと思ったためです。
ローカルで自動フォーマットされるのでこけたことはないです

## ドキュメント生成
`master` ブランチの push (PR の merge も含む) をトリガーに `cargo doc --no-deps` して、 GitHub Pages に上げています。最近のスタンダードな2段階構成(？)のやり方です。

- [actions/upload-pages-artifact](https://github.com/actions/upload-pages-artifact) を使って `cargo doc` に生成された doc を artifact に上げ、

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L31-L36

- [actions/deploy-pages](https://github.com/actions/deploy-pages) を使ってその artifact を GitHub Pages に反映しています。

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L42-L54


`cargo doc` とかをしていると .lock みたいなパーミッションが 600 のファイルが生成され、それがあるとうまく GitHub Pages に反映できずこけるため、そのファイルを消すなどしないといけないというちょっとした落とし穴があります。
https://github.com/orgs/community/discussions/40771#discussioncomment-8344735

紹介した GitHub Actions によって、↓の GitHub Pages の URLにドキュメントをアップロードしています
- https://hayas1.github.io/json-with-comments/json_with_comments/

https://hayas1.github.io/json-with-comments/json_with_comments/

docについては [crates.io](https://crates.io/) に公開すると [docs.rs](https://docs.rs/) に上がるそうなので、そこまで必要ないことかもしれないですね

## カバレッジ計測
test のカバレッジに計測に [cargo-tarpaulin](https://crates.io/crates/cargo-tarpaulin) を使ってみています。
`cargo tarpaulin --output-dir target/doc --manifest-path Cargo.toml --out Html` などすると target/doc 配下にカバレッジに関しての HTML が置かれるようなので、これについてもドキュメントと同様に GitHub Pages に上げています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L27-L30

↓のURLにカバレッジについてアップロードされてます。あたらめて見ると 68.75% となかなか低かったです… 😰 もっとテストを拡充していったほうがよさそう、というよう気持ちになれるので、気軽にカバレッジが確認できるのはなかなかよいですね
- https://hayas1.github.io/json-with-comments/tarpaulin-report

https://hayas1.github.io/json-with-comments/tarpaulin-report

## READMEの追従漏れチェック
ドキュメントのために `lib.rs` にクレートの概要や使い方を書くわけですが、これって `README.md` とだいたい同じですよね。というわけで、[cargo-readme](https://github.com/webern/cargo-readme)を使って、[lib.rs](https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/lib.rs) のドキュメントから [README.md](https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md) を自動生成します。

とはいえ、CIにコミットされるのはあまりうれしくないと思っているので、コミット自体は手動で行うことになります。
そこで、CIでは `cargo readme` を実行して生成される `README.md` に差分が無いかだけを確認しています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L34-L35

`README.md` の更新が漏れていると CI がこけて気づくことができるので、個人的にはよい落としどころだったかなと思っています。

## タグの付与
Rust のプログラムを Git 管理すると、`Cargo.toml` に書いているバージョンと、Git でつけるタグのバージョンで、2つのバージョンを管理することになります。
それらの同期を手動でとるのは大変なので、 `Cargo.toml` に書いてあるバージョンで Git にもタグをつけるようにしたいです。そこで、CI ではそれらの差分を検知する [composite action](https://docs.github.com/ja/actions/creating-actions/creating-a-composite-action) を用意して、柔軟に使えるようにしています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/actions/versions/action.yml#L24-L46

- たとえば、PR がトリガーの CI では、マージするとバージョンが上がる場合に `release` のラベルを付与しています

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L37-L52

- また、master ブランチの CI では、`Cargo.toml` のバージョンが 上がった場合に、実際にタグを付与しています

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L56-L68

こうして、 `Cargo.toml` に書くバージョンだけを管理すればよい状態にすることができました。(実際はこの CI だとバージョンが上がったことは検知できておらず、 `Cargo.toml` と Git でバージョンが違うかどうかだけしか見られていないことは内緒です)

## リリースドラフト作成
GitHub でリリースをいい感じに作るとなると、主な選択肢は2つあります。release-drafter と GitHub 公式のリリースノート自動生成機能です。
https://github.com/release-drafter/release-drafter
https://docs.github.com/ja/repositories/releasing-projects-on-github/automatically-generated-release-notes

release-drafter も機能が豊富でいいですが、今回は公式のものを使うことにしました。公式のものについて機能を簡単に説明すると、↓のような `.github/release.yml` を書いておくと、 PR のタイトルやラベルをもとにリリースノートを自動生成できるようになります。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/release.yml#L1-L23

リリース作成時に 「Generate Release Notes」ボタンを押すと、自動生成されたリリースノートを埋めてもらえるという感じです。
「Generate Release Notes」ボタンの画像は↓の公式ドキュメントの中にこっそり写ってます
https://docs.github.com/ja/repositories/releasing-projects-on-github/automatically-generated-release-notes#creating-automatically-generated-release-notes-for-a-new-release
いくつかリリースをしていますが、リリースノートはこうやって自動作成されています。
https://github.com/hayas1/json-with-comments/releases/tag/v0.1.5

なお、PR にある自動でラベルをつけるために、 [actions/labeler](https://github.com/actions/labeler) を使ってます。↓のような `.github/labeler.yml` を書いておいてワークフローを呼び出すと、PR のブランチ名や、変更のあったパスなどに応じてラベルを付与してくれます。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/labeler.yml#L1-L39

ワークフローの呼び出しも↓のように簡単にできるので、とても扱いやすいものになっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/labeler.yml#L1-L12

ちなみに、「Generate Release Notes」ボタンを手動で押すために、 master ブランチの CI では、リリースのドラフトだけを作成するようになっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L68-L75
「Generate Release Notes」ボタンを押したときに得られる文字列は、GitHub の API を叩くことで手に入れられるようなのですが、そこにはまだ取り組めていないです。 公式の機能なのでリリースドラフトを用意するのに使っている [actions/create-release](https://github.com/actions/create-release) にやってもらいたいところでもあるものの、もうアーカイブされてしまっているようなので望み薄ですね 😥


# 感想
serdeが提供する抽象化に沿ってコードを書いていけばいい感じのパーサーを作ることができてすごいです。
一方で、記述量はその分なかなか多くなります。自分で工夫できる領域も少なくなるのでちょっと物足りない部分もあります。
とはいえ、serde や serde_json を使っているときの結局これは何なんだろうみたいな気持ちからは解放されそうなので、JSONC パーサーを書いてみて良かったと思います。

