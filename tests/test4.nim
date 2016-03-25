import marshal


const js = """{"address": {"building": "13335", "coord": [-73.8330519, 40.7587756], "street": "Roosevelt Ave", "zipcode": "11354"}, "borough": "Queens", "cuisine": "Chinese", "grades": [{"date": 1421712000000, "grade": "Not Yet Graded", "score": null}], "name": "Peng Shun Restaurant", "restaurant_id": "50016322"}"""

type
  Restaurant = object
    address: tuple[building: string, coord: array[2, float], street: string, zipcode: string]
    borough: string
    cuisine: string
    grades: seq[tuple[date: int, grade: char, score: int]]
    name: string

var resp = to[Restaurant](js)
#echo resp.grades
