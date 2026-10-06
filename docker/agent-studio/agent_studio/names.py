"""Nome amigável da conversa (#530): `Adjetivo_Substantivo` tirado do próprio `session.id` por função fixa.

Nada é guardado: o mesmo id dá o mesmo nome em toda tela. Dois ids podem cair no mesmo nome (64 × 64 = 4096
combinações), por isso a tela mostra o id inteiro junto.

Nome da rodada do swarm (#605): sorteado na abertura (`draw`) entre os que nenhuma rodada aberta usa, e gravado no `meta` dela;
o `oute-swarm` chama `python3 names.py draw [nome…]` (as mesmas listas, uma fonte só). As palavras são em inglês; o substantivo é animal ou pessoa."""
import hashlib
import secrets
import sys

ADJECTIVES = (
    "Agile", "Amber", "Ancient", "Bold", "Brave", "Bright", "Brisk", "Calm", "Clever", "Cosmic", "Crisp", "Curious",
    "Daring", "Dapper", "Eager", "Electric", "Fancy", "Fearless", "Fluffy", "Frosty", "Gentle", "Giant", "Glad",
    "Golden", "Happy", "Hasty", "Humble", "Jolly", "Keen", "Kind", "Lively", "Lucky", "Mellow", "Merry", "Mighty",
    "Misty", "Nimble", "Noble", "Odd", "Patient", "Peppy", "Plucky", "Polite", "Proud", "Quick", "Quiet", "Rapid",
    "Relaxed", "Rustic", "Shiny", "Silent", "Silly", "Sleepy", "Snappy", "Sunny", "Swift", "Tidy", "Tiny", "Vivid",
    "Warm", "Wild", "Wise", "Witty", "Zesty",
)
ANIMALS = (
    "Badger", "Bat", "Bear", "Beaver", "Bison", "Cat", "Cheetah", "Crane", "Dolphin", "Eagle", "Falcon", "Ferret",
    "Fox", "Frog", "Gecko", "Heron", "Hedgehog", "Koala", "Lemur", "Lynx", "Otter", "Owl", "Panda", "Parrot",
    "Penguin", "Rabbit", "Raven", "Seal", "Tiger", "Turtle", "Whale", "Wolf",
)
PEOPLE = (
    "Artist", "Baker", "Captain", "Chef", "Climber", "Diver", "Doctor", "Dancer", "Explorer", "Farmer", "Gardener",
    "Hiker", "Inventor", "Judge", "Knight", "Miner", "Painter", "Pilot", "Poet", "Ranger", "Sailor", "Scholar",
    "Singer", "Skater", "Sculptor", "Surfer", "Tailor", "Teacher", "Traveler", "Weaver", "Wizard", "Writer",
)
NOUNS = ANIMALS + PEOPLE


def friendly(conversation_id):
    """`Flat_Bear`: o nome da conversa, sempre o mesmo para o mesmo id (SHA-256 do id, sem estado)."""
    digest = hashlib.sha256(str(conversation_id).encode("utf-8")).digest()
    adjective = ADJECTIVES[int.from_bytes(digest[:4], "big") % len(ADJECTIVES)]
    noun = NOUNS[int.from_bytes(digest[4:8], "big") % len(NOUNS)]
    return f"{adjective}_{noun}"


def draw(taken=()):
    """Nome da rodada (#605): `Adjetivo_Substantivo` sorteado entre os que não estão em `taken`. `None` se não sobrou nenhum."""
    used = set(taken)
    free = [f"{a}_{n}" for a in ADJECTIVES for n in NOUNS if f"{a}_{n}" not in used]
    return secrets.choice(free) if free else None


def _main(argv):
    """`names.py draw [nome…]`: imprime o nome sorteado (saída 1, sem saída, se não sobrou nenhum)."""
    if len(argv) >= 2 and argv[1] == "draw":
        name = draw(argv[2:])
        if name:
            print(name)
            return 0
        return 1
    print("uso: names.py draw [nome…]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
