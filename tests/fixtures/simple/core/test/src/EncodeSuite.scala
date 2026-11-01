package example

class EncodeSuite extends munit.FunSuite {
  test("numbers") {
    assertEquals(Encode.numbers(Seq(1, 2)), "[1,2]")
  }
}
