{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeInType             #-}
{-# LANGUAGE TypeOperators          #-}

module Database.Bolt.Extras.DSL.Typed.Types where

import           Data.Kind                               (Constraint, Type)
import           Data.Text                               (Text)
import qualified Database.Bolt                           as B
import           GHC.Generics                            (Rep)
import           GHC.TypeLits                            (KnownSymbol, Symbol)

import qualified Database.Bolt.Extras.DSL                as UT

import           Database.Bolt.Extras.DSL.Typed.Families

{- $setup
>>> :set -XDeriveGeneric
>>> :set -XTypeApplications
>>> :set -XOverloadedLabels
>>> :load Database.Bolt.Extras.DSL.Typed.Instances
>>> import Data.Text (unpack)
>>> import GHC.Generics (Generic)
>>> import Database.Bolt.Extras (toCypher)
>>> toCypherN = putStrLn . unpack . toCypher  . nodeSelector
-}

-- | Class for Selectors that know type of their labels. This class is kind-polymorphic,
-- so that instances may select a specific collection of labels they support.
--
-- __NOTE__: Due to the way GHC orders type variables for class methods, it's more convenient
-- to use 'lbl' and 'prop' synonyms defined below, and 'withLabel' and 'withProp' methods
-- should be considered an implementation detail.
class SelectorLike (a :: k -> Type) where
  -- | This constraint checks that current collection of types supports adding one more.
  type CanAddType (types :: k) :: Constraint

  -- | This type family implements adding a new type (of label) to the collection.
  --
  -- Injectivity annotation is required to make type inference possible.
  type AddType (types :: k) (typ :: Type) = (result :: k) | result -> types typ

  -- | This constraint checks that field with this name has correct type in the collection
  -- of labels.
  type HasField (types :: k) (field :: Symbol) (typ :: Type) :: Constraint

  -- | This constraint checks that field with this name exists in the collection, with any type.
  type HasField' (types :: k) (field :: Symbol) :: Constraint

  -- | Set an identifier — Cypher variable name.
  withIdentifier :: Text -> a types -> a types

  -- | Add a new label, if possible.
  withLabel
    :: CanAddType types
    => KnownSymbol (GetTypeName (Rep typ))
    => a types
    -> a (AddType types typ)

  -- | Add a property with value, checking that such property exists.
  withProp
    :: HasField types field typ
    => B.IsValue typ
    => (SymbolS field, typ)
    -> a types
    -> a types

  -- | Add a property as named parameter (@$foo@). Only checks that given property exists,
  -- no matter its type.
  withParam
    :: HasField' types field
    => (SymbolS field, Text)
    -> a types
    -> a types

-- | Constraint for types that may be used with 'lbl'.
type LabelConstraint (typ :: Type) = KnownSymbol (GetTypeName (Rep typ))

-- | Synonym for 'withLabel' with label type variable as first one, enabling @lbl \@Foo@ type
-- application syntax.
lbl
  :: forall (typ :: Type) k (types :: k) (a :: k -> Type)
  .  SelectorLike a
  => CanAddType types
  => KnownSymbol (GetTypeName (Rep typ))
  => a types
  -> a (AddType types typ)
lbl = withLabel

-- | Shorter synonym for 'withProp'.
--
-- Properties of type @Maybe a@ are treated as properties of type @a@, since there is no difference
-- between the two in Cypher.
--
-- >>> data Foo = Foo { foo :: Int, bar :: Maybe String } deriving Generic
-- >>> toCypherN $ defN .& lbl @Foo .& prop (#foo =: 42)
-- (:Foo{foo:42})
-- >>> toCypherN $ defN .& lbl @Foo .& prop (#bar =: "hello")
-- (:Foo{bar:"hello"})
prop
  :: forall (field :: Symbol) k (a :: k -> Type) (types :: k) (typ :: Type)
  .  SelectorLike a
  => HasField types field typ
  => B.IsValue typ
  => (SymbolS field, typ) -- ^ Field name along with its value. This pair should be constructed with '=:'.
  -> a types -> a types
prop = withProp

-- | A variant of 'prop' that accepts values in @Maybe@. If given @Nothing@, does nothing.
--
-- This works both for properties with @Maybe@ and without.
--
-- >>> data Foo = Foo { foo :: Int, bar :: Maybe String } deriving Generic
-- >>> toCypherN $ defN .& lbl @Foo .& propMaybe (#foo =: Just 42)
-- (:Foo{foo:42})
-- >>> toCypherN $ defN .& lbl @Foo .& propMaybe (#bar =: Nothing)
-- (:Foo)
propMaybe
  :: forall (field :: Symbol) k (a :: k -> Type) (types :: k) (typ :: Type)
  .  SelectorLike a
  => HasField types field typ
  => B.IsValue typ
  => (SymbolS field, Maybe typ)
  -> a types -> a types
propMaybe (name, Just val) = withProp (name, val)
propMaybe _                = id

-- | Shorter synonym for 'withParam'.
--
-- >>> data Foo = Foo { foo :: Int, bar :: Maybe String } deriving Generic
-- >>> toCypherN $ defN .& lbl @Foo .& param (#foo =: "foo")
-- (:Foo{foo:$foo})
-- >>> toCypherN $ defN .& lbl @Foo .& prop (#foo =: 42) .& param (#bar =: "bar")
-- (:Foo{foo:42,bar:$bar})
-- >>> toCypherN $ defN .& lbl @Foo .& param (#baz =: "baz")
-- ...
-- ... There is no field "baz" in any of the records
-- ... '[Foo]
-- ...
--
-- __NOTE__: this will add @$@ symbol to parameter name automatically.
param
  :: forall (field :: Symbol) k (a :: k -> Type) (types :: k)
  .  SelectorLike a
  => HasField' types field
  => (SymbolS field, Text)
  -> a types -> a types
param = withParam

-- | Smart constructor for type-level tuples, to avoid writing @'("foo", Int)@ with extra tick.
type (=:) (a :: k) (b :: l) = '(a, b)

-- | Smart constructor for a pair of field name and its value. To be used with @OverloadedLabels@:
--
-- > #uuid =: "123"
(=:) :: forall (field :: Symbol) (typ :: Type). SymbolS field -> typ -> (SymbolS field, typ)
(=:) = (,)

-- | A wrapper around 'Database.Extras.DSL.NodeSelector' with phantom type.
--
-- Node selectors remember arbitrary number of labels in a type-level list.
newtype NodeSelector (typ :: [Type])
  = NodeSelector
      { nodeSelector :: UT.NodeSelector -- ^ Convert to untyped 'UT.NodeSelector'.
      }
    deriving (Show, Eq)

-- | A wrapper around 'Database.Extras.DSL.RelSelector' with phantom type.
--
-- Relationship selectors remember at most one label in a type-level @Maybe@.
newtype RelSelector (typ :: Maybe Type)
  = RelSelector
      { relSelector :: UT.RelSelector -- ^ Convert to untyped 'UT.RelSelector'.
      }
    deriving (Show, Eq)

newtype SymbolS (s :: Symbol) = SymbolS { getSymbol :: String }
  deriving (Show)

-- | An empty 'NodeSelector'.
defN :: NodeSelector '[]
defN = NodeSelector UT.defaultNode

-- | An empty 'RelSelector'.
defR :: RelSelector 'Nothing
defR = RelSelector UT.defaultRel

infixl 3 .&
-- | This is the same as 'Data.Function.&', but with higher precedence, so that it binds before
-- path combinators.
(.&) :: a -> (a -> b) -> b
a .& f = f a
{-# INLINE (.&) #-}

infixl 2 !->:
-- | See 'UT.:!->:'. This combinator forgets type-level information from the selectors.
(!->:) :: RelSelector a -> NodeSelector b -> UT.PathPart
RelSelector r !->: NodeSelector n = r UT.:!->: n

infixl 2 !-:
-- | See 'UT.:!-:'. This combinator forgets type-level information from the selectors.
(!-:) :: RelSelector a -> NodeSelector b -> UT.PathPart
RelSelector r !-: NodeSelector n = r UT.:!-: n

infixl 1 -:
-- | See 'UT.-:'. This combinator forgets type-level information from the selectors.
(-:) :: NodeSelector a -> UT.PathPart -> UT.PathSelector
NodeSelector ns -: pp = UT.P ns UT.:-!: pp

infixl 1 <-:
-- | See 'UT.<-:'. This combinator forgets type-level information from the selectors.
(<-:) :: NodeSelector a -> UT.PathPart -> UT.PathSelector
NodeSelector ns <-: pp = UT.P ns UT.:<-!: pp

-- | See 'UT.P'. This combinator forgets type-level information from the selectors.
p :: NodeSelector a -> UT.PathSelector
p (NodeSelector ns) = UT.P ns

