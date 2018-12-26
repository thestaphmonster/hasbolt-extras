{-# LANGUAGE AllowAmbiguousTypes     #-}
{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE OverloadedStrings       #-}
{-# LANGUAGE QuasiQuotes             #-}
{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE TypeApplications        #-}
{-# LANGUAGE TypeFamilies            #-}
{-# LANGUAGE TypeFamilyDependencies  #-}

module Database.Bolt.Extras.Graph.Internal.GraphQuery
  (
    GraphQuery (..)
  , GetRequestA (..)
  , GetRequestB (..)
  , mergeGraphs
  ) where

import           Control.Lens                                      (over, (^.))
import           Control.Monad.IO.Class                            (MonadIO)
import           Data.List                                         (foldl')
import           Data.Map.Strict                                   (fromList,
                                                                    keys,
                                                                    mapKeys,
                                                                    mapWithKey,
                                                                    toList,
                                                                    union, (!))
import           Data.Maybe                                        (catMaybes)
import           Data.Monoid                                       ((<>))
import           Data.Text                                         (Text,
                                                                    intercalate,
                                                                    pack)
import           Database.Bolt                                     (BoltActionT,
                                                                    Node,
                                                                    Record,
                                                                    URelationship,
                                                                    query)
import           Database.Bolt.Extras                              (GetBoltId (..))
import           Database.Bolt.Extras.Graph.Internal.AbstractGraph (Graph (..),
                                                                    emptyGraph,
                                                                    relations,
                                                                    vertices)
import           Database.Bolt.Extras.Graph.Internal.Class         (Extractable (..),
                                                                    Requestable (..),
                                                                    Returnable (..))
import           Database.Bolt.Extras.Graph.Internal.Get           (NodeGetter,
                                                                    NodeName,
                                                                    NodeResult,
                                                                    RelGetter,
                                                                    RelResult,
                                                                    relationName)
import           NeatInterpolation                                 (text)

-- | Type family used to perform requests to the Neo4j based on graphs.
--
class GraphQuery a where
  -- | Type of entity, describing node for request.
  type NodeReq a :: *
  -- | Type of entity, describing relationship for request.
  type RelReq  a :: *
  -- | Type of node entity, which will be extracted from result.
  type NodeRes a :: *
  -- | Type of relationship entity, which will be extracted from result.
  type RelRes  a :: *

  -- | 'MATCH' or 'MERGE' or 'CREATE'
  clause :: Text

  -- | Abstract function to form query for get request.
  --
  formQuery :: (Requestable (NodeName, NodeReq a),
                Requestable ((NodeName, NodeName), RelReq a),
                Returnable (NodeName, NodeReq a),
                Returnable ((NodeName, NodeName), RelReq a))
            => [Text]
            -> Graph NodeName (NodeReq a) (RelReq a)
            -> Text
  formQuery customConds graph = [text|$clause' $completeRequest
                                      $conditionsQ
                                      RETURN $completeReturn|]
    where
      clause'          = clause @a

      vertices'        = toList (graph ^. vertices)
      relations'       = toList (graph ^. relations)

      requestVertices  = request <$> vertices'
      requestRelations = request <$> relations'

      conditionsID     = catMaybes (fmap maybeBoltIdCond vertices' ++ fmap maybeBoltIdCond relations')
      conditions       = customConds ++ conditionsID
      conditionsQ      = if null conditions then "" else "WHERE " <> intercalate " AND " conditions

      returnVertices   = return' <$> vertices'
      returnRelations  = return' <$> relations'

      completeRequest  = intercalate ", " $ requestVertices ++ requestRelations
      completeReturn   = intercalate ", " $ returnVertices  ++ returnRelations

  -- | Abstract function, which exctracts graph from records if nodes and relations can be extracted.
  --
  extractGraphs :: (Extractable (NodeRes a), Extractable (RelRes a), MonadIO m)
                => [NodeName]
                -> [(NodeName, NodeName)]
                -> [Record]
                -> BoltActionT m [Graph NodeName (NodeRes a) (RelRes a)]
  extractGraphs verticesN relationsN records = mapM (\i -> do
        vertices'  <- zip verticesN  <$> traverse (fmap (!! i) . flip extract records               ) verticesN
        relations' <- zip relationsN <$> traverse (fmap (!! i) . flip extract records . relationName) relationsN
        pure $ Graph (fromList vertices') (fromList relations'))
      [0 .. length records - 1]

  -- | For given query graph, perform query and extract results graph.
  --
  makeRequest :: (Requestable (NodeName, NodeReq a),
                  Requestable ((NodeName, NodeName), RelReq a),
                  Returnable (NodeName, NodeReq a),
                  Returnable ((NodeName, NodeName), RelReq a),
                  Extractable (NodeRes a),
                  Extractable (RelRes a),
                  MonadIO m)
              => [Text]
              -> Graph NodeName (NodeReq a) (RelReq a)
              -> BoltActionT m [Graph NodeName (NodeRes a) (RelRes a)]
  makeRequest conds graph = do
      response <- query $ formQuery @a conds graph
      extractGraphs @a (keys $ graph ^. vertices) (keys $ graph ^. relations) response

-- | Get request with result in Aeson format.
-- Easy way to show result graphs.
--
data GetRequestA = GetRequestA

-- | Get request with result in Bolt format.
-- Easy way to extract results and convert them to another entities (using 'fromNode').
--
data GetRequestB = GetRequestB

instance GraphQuery GetRequestA where
  type NodeReq GetRequestA = NodeGetter
  type RelReq  GetRequestA = RelGetter
  type NodeRes GetRequestA = NodeResult
  type RelRes  GetRequestA = RelResult
  clause                   = "MATCH"

instance GraphQuery GetRequestB where
  type NodeReq GetRequestB = NodeGetter
  type RelReq  GetRequestB = RelGetter
  type NodeRes GetRequestB = Node
  type RelRes  GetRequestB = URelationship
  clause                   = "MATCH"

-- | Helper function to merge graphs of results, i.e.
-- if you requested graph A->B->C
-- and in the database there were two B entities connected to the same entity A
-- and four C entities, connected to the same two entities B,
-- cypher query will return four graphs, which satisfy this path,
-- despite the fact that A was presented only once in the database
-- and B was presented only two times in the database.
-- This function will merge these four graphs in one
-- and return nodes by node names with suffixes equal to their BoltId-s.
--
-- For example, if there were four graphs:
-- nodes: [A (boltId = 0), B (boltId = 1), C (boltId = 3)], relations: [A -> B, B -> C],
-- nodes: [A (boltId = 0), B (boltId = 1), C (boltId = 4)], relations: [A -> B, B -> C],
-- nodes: [A (boltId = 0), B (boltId = 2), C (boltId = 5)], relations: [A -> B, B -> C],
-- nodes: [A (boltId = 0), B (boltId = 2), C (boltId = 6)], relations: [A -> B, B -> C],
-- this function will merge them into new graph:
-- nodes: [A0 (boltId = 0), B1 (boltId = 1), B2 (boltId = 2),
--         C3 (boltId = 3), C4 (boltId = 4), C5 (boltId = 5), C6 (boltId = 6)],
-- relations: [A0 -> B1, A0 -> B2, B1 -> C3, B1 -> C4, B2 -> C5, B2 -> C6].
--
mergeGraphs :: GetBoltId a => [Graph NodeName a b] -> Graph NodeName a b
mergeGraphs graphs = foldl' mergeGraph emptyGraph (updateGraph <$> graphs)
  where
    updateGraph :: GetBoltId a => Graph NodeName a b -> Graph NodeName a b
    updateGraph graph = Graph newVertices newRelations
      where
        namesMap     = (\name        node     ->  name <> (pack . show . getBoltId $ node)  ) `mapWithKey` (graph ^. vertices)
        newVertices  = (\name                 ->  namesMap ! name                           ) `mapKeys`    (graph ^. vertices)
        newRelations = (\(startName, endName) -> (namesMap ! startName, namesMap ! endName) ) `mapKeys`    (graph ^. relations)

    mergeGraph :: GetBoltId a => Graph NodeName a b -> Graph NodeName a b -> Graph NodeName a b
    mergeGraph graphToMerge initialGraph = over relations (union (graphToMerge ^. relations)) $
                                           over vertices  (union (graphToMerge ^. vertices))
                                           initialGraph
