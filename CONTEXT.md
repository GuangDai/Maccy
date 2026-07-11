# Clipboard History Context

Maccy retains clipboard history and presents it for search, selection, pinning, and reuse. This glossary distinguishes a retained item from its storage and presentation identities.

## Language

**History Item**:
A retained clipboard entry containing one or more representations of the same copy plus its metadata.
_Avoid_: Clipboard item, row, record

**Stored Item Identity**:
The stable identity of one History Item within a history store.
_Avoid_: ItemID, decorator ID, content hash

**Presentation Identity**:
The temporary identity of one in-memory presentation of a History Item; replacing the presentation creates a new identity without changing the History Item.
_Avoid_: Stored Item Identity, persistent ID

**Content Signature**:
The order-independent description of a History Item's content representations used to find possible duplicates.
_Avoid_: Item identity, content fingerprint

**Content Fingerprint**:
A digest of one content representation used inside a Content Signature; it is evidence for duplicate detection, not item identity.
_Avoid_: Item ID, signature

**Copy Origin**:
The pasteboard event and source application associated with a copy.
_Avoid_: History Item Identity
