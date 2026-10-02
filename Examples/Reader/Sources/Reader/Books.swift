//
//  Books.swift
//  Reader
//
//  The shelf: the opening pages of three public-domain novels.
//

import NucleantUI

extension Book {
    static let shelf: [Book] = [alice, prideAndPrejudice, mobyDick]

    static let alice = Book(
        id: 1,
        title: "Alice’s Adventures in Wonderland",
        author: "Lewis Carroll",
        year: 1865,
        blurb: "A bored girl follows a White Rabbit down a hole and into a world where size, sense and manners will not hold still.",
        cover: Color(hex: 0x3F7A5A),
        coverShade: Color(hex: 0x24493A),
        coverInk: Color(hex: 0xF3E9C6),
        chapters: [
            Chapter(title: "Down the Rabbit-Hole", paragraphs: [
                "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, ‘and what is the use of a book,’ thought Alice ‘without pictures or conversations?’",
                "So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.",
                "There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself, ‘Oh dear! Oh dear! I shall be late!’ (when she thought it over afterwards, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural); but when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge.",
                "In another moment down went Alice after it, never once considering how in the world she was to get out again.",
                "The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.",
                "Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs. She took down a jar from one of the shelves as she passed; it was labelled ‘ORANGE MARMALADE’, but to her great disappointment it was empty: she did not like to drop the jar for fear of killing somebody underneath, so managed to put it into one of the cupboards as she fell past it.",
            ]),
            Chapter(title: "The Pool of Tears", paragraphs: [
                "‘Curiouser and curiouser!’ cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); ‘now I’m opening out like the largest telescope that ever was! Good-bye, feet!’ (for when she looked down at her feet, they seemed to be almost out of sight, they were getting so far off). ‘Oh, my poor little feet, I wonder who will put on your shoes and stockings for you now, dears? I’m sure I shan’t be able! I shall be a great deal too far off to trouble myself about you: you must manage the best way you can;—but I must be kind to them,’ thought Alice, ‘or perhaps they won’t walk the way I want to go! Let me see: I’ll give them a new pair of boots every Christmas.’",
                "And she went on planning to herself how she would manage it. ‘They must go by the carrier,’ she thought; ‘and how funny it’ll seem, sending presents to one’s own feet! And how odd the directions will look!’",
                "Just then her head struck against the roof of the hall: in fact she was now more than nine feet high, and she at once took up the little golden key and hurried off to the garden door.",
                "Poor Alice! It was as much as she could do, lying down on one side, to look through into the garden with one eye; but to get through was more hopeless than ever: she sat down and began to cry again.",
            ]),
        ]
    )

    static let prideAndPrejudice = Book(
        id: 2,
        title: "Pride and Prejudice",
        author: "Jane Austen",
        year: 1813,
        blurb: "A wealthy young man takes Netherfield Park, and the Bennet household — five daughters and a mother determined to marry them — takes notice.",
        cover: Color(hex: 0x8C3B4A),
        coverShade: Color(hex: 0x56212C),
        coverInk: Color(hex: 0xF6E7D8),
        chapters: [
            Chapter(title: nil, paragraphs: [
                "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
                "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.",
                "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”",
                "Mr. Bennet replied that he had not.",
                "“But it is,” returned she; “for Mrs. Long has just been here, and she told me all about it.”",
                "Mr. Bennet made no answer.",
                "“Do not you want to know who has taken it?” cried his wife impatiently.",
                "“You want to tell me, and I have no objection to hearing it.”",
                "This was invitation enough.",
                "“Why, my dear, you must know, Mrs. Long says that Netherfield is taken by a young man of large fortune from the north of England; that he came down on Monday in a chaise and four to see the place, and was so much delighted with it that he agreed with Mr. Morris immediately; that he is to take possession before Michaelmas, and some of his servants are to be in the house by the end of next week.”",
                "“What is his name?”",
                "“Bingley.”",
                "“Is he married or single?”",
                "“Oh! single, my dear, to be sure! A single man of large fortune; four or five thousand a year. What a fine thing for our girls!”",
                "“How so? how can it affect them?”",
                "“My dear Mr. Bennet,” replied his wife, “how can you be so tiresome! You must know that I am thinking of his marrying one of them.”",
                "“Is that his design in settling here?”",
                "“Design! nonsense, how can you talk so! But it is very likely that he may fall in love with one of them, and therefore you must visit him as soon as he comes.”",
            ]),
            Chapter(title: nil, paragraphs: [
                "Mr. Bennet was among the earliest of those who waited on Mr. Bingley. He had always intended to visit him, though to the last always assuring his wife that he should not go; and till the evening after the visit was paid she had no knowledge of it. It was then disclosed in the following manner. Observing his second daughter employed in trimming a hat, he suddenly addressed her with:",
                "“I hope Mr. Bingley will like it, Lizzy.”",
                "“We are not in a way to know what Mr. Bingley likes,” said her mother resentfully, “since we are not to visit.”",
                "“But you forget, mamma,” said Elizabeth, “that we shall meet him at the assemblies, and that Mrs. Long promised to introduce him.”",
                "“I do not believe Mrs. Long will do any such thing. She has two nieces of her own. She is a selfish, hypocritical woman, and I have no opinion of her.”",
                "“No more have I,” said Mr. Bennet; “and I am glad to find that you do not depend on her serving you.”",
                "Mrs. Bennet deigned not to make any reply, but, unable to contain herself, began scolding one of her daughters.",
                "“Don’t keep coughing so, Kitty, for Heaven’s sake! Have a little compassion on my nerves. You tear them to pieces.”",
                "“Kitty has no discretion in her coughs,” said her father; “she times them ill.”",
                "“I do not cough for my own amusement,” replied Kitty fretfully.",
            ]),
        ]
    )

    static let mobyDick = Book(
        id: 3,
        title: "Moby-Dick",
        author: "Herman Melville",
        year: 1851,
        blurb: "A schoolmaster with a damp, drizzly November in his soul goes to sea, and signs on to a whaler whose captain is hunting one whale in particular.",
        cover: Color(hex: 0x2E5C86),
        coverShade: Color(hex: 0x17304A),
        coverInk: Color(hex: 0xE8EEF2),
        chapters: [
            Chapter(title: "Loomings", paragraphs: [
                "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. It is a way I have of driving off the spleen and regulating the circulation. Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly November in my soul; whenever I find myself involuntarily pausing before coffin warehouses, and bringing up the rear of every funeral I meet; and especially whenever my hypos get such an upper hand of me, that it requires a strong moral principle to prevent me from deliberately stepping into the street, and methodically knocking people’s hats off—then, I account it high time to get to sea as soon as I can. This is my substitute for pistol and ball. With a philosophical flourish Cato throws himself upon his sword; I quietly take to the ship. There is nothing surprising in this. If they but knew it, almost all men in their degree, some time or other, cherish very nearly the same feelings towards the ocean with me.",
                "There now is your insular city of the Manhattoes, belted round by wharves as Indian isles by coral reefs—commerce surrounds it with her surf. Right and left, the streets take you waterward. Its extreme downtown is the battery, where that noble mole is washed by waves, and cooled by breezes, which a few hours previous were out of sight of land. Look at the crowds of water-gazers there.",
                "Circumambulate the city of a dreamy Sabbath afternoon. Go from Corlears Hook to Coenties Slip, and from thence, by Whitehall, northward. What do you see?—Posted like silent sentinels all around the town, stand thousands upon thousands of mortal men fixed in ocean reveries. Some leaning against the spiles; some seated upon the pier-heads; some looking over the bulwarks of ships from China; some high aloft in the rigging, as if striving to get a still better seaward peep. But these are all landsmen; of week days pent up in lath and plaster—tied to counters, nailed to benches, clinched to desks. How then is this? Are the green fields gone? What do they here?",
            ]),
            Chapter(title: "The Carpet-Bag", paragraphs: [
                "I stuffed a shirt or two into my old carpet-bag, tucked it under my arm, and started for Cape Horn and the Pacific. Quitting the good city of old Manhatto, I duly arrived in New Bedford. It was a Saturday night in December. Much was I disappointed upon learning that the little packet for Nantucket had already sailed, and that no way of reaching that place would offer, till the following Monday.",
                "As most young candidates for the pains and penalties of whaling stop at this same New Bedford, thence to embark on their voyage, it may as well be related that I, for one, had no idea of so doing. For my mind was made up to sail in no other than a Nantucket craft, because there was a fine, boisterous something about everything connected with that famous old island, which amazingly pleased me.",
            ]),
        ]
    )
}
